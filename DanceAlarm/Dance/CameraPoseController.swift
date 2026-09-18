import AVFoundation
import Foundation
import SwiftUI
import Vision

/// 相机 + Vision 姿态识别的控制器。
///
/// 与安卓版的差异说明：
///  - 安卓用 ML Kit 的姿态模型（需打包 37MB 原生库）；iOS 直接用系统内置的 Vision
///    `VNDetectHumanBodyPoseRequest`（iOS 14+），**零额外依赖、零体积开销**，且完全离线。
///  - 坐标约定：Vision 的输出是以**左下角为原点**的归一化坐标（y 轴向上），
///    而界面绘制用的是左上角原点（y 轴向下），所以这里统一做一次 y 翻转，
///    并同时输出「像素坐标」（给判定引擎）与「归一化坐标」（给骨骼叠加绘制）。
///  - 旋转：把采集连接的旋转角固定成竖屏，这样 buffer 到手就是正立的，
///    Vision 按 `.up` 处理即可 —— 比安卓版那套「自己猜坐标系朝向」的启发式可靠得多。
final class CameraPoseController: NSObject, ObservableObject {

    @Published private(set) var snapshot: DanceSnapshot
    @Published private(set) var cameraError: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "dancealarm.camera.session")
    private let analysisQueue = DispatchQueue(label: "dancealarm.camera.analysis")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let judge: DanceJudge
    private let poseRequest = VNDetectHumanBodyPoseRequest()

    private var isConfigured = false
    private var hasFinished = false

    /// 判定达标时回调（已切回主线程）
    var onCompleted: (() -> Void)?

    init(requiredMs: Int64) {
        self.judge = DanceJudge(requiredMs: requiredMs)
        self.snapshot = DanceSnapshot.initial(requiredMs: requiredMs)
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.cameraError = "没有相机权限，无法进行舞蹈检测。请到「设置 → 隐私与安全性 → 相机」里为本应用开启。"
                }
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.sessionPreset = .high

        // 前置摄像头：对着用户
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.cameraError = "摄像头启动失败：找不到可用的前置摄像头。"
            }
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // 让采集出来的画面直接就是竖屏正立的，Vision 就不必再猜坐标系朝向。
        // 同时明确关闭镜像：预览层负责镜像（照镜子更自然），分析用的 buffer 用原始朝向，
        // 骨骼叠加绘制时再统一补一次水平翻转。
        if let conn = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else {
                if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }

        session.commitConfiguration()
    }

    // MARK: - Vision 关节 → 引擎关键点

    /// 把 Vision 的关节名映射到引擎的编号（沿用安卓版 ML Kit 的编号，便于两端对照）
    private static let jointIndex: [VNHumanBodyPoseObservation.JointName: Int] = [
        .nose: Joint.nose,
        .leftShoulder: Joint.leftShoulder,
        .rightShoulder: Joint.rightShoulder,
        .leftElbow: Joint.leftElbow,
        .rightElbow: Joint.rightElbow,
        .leftWrist: Joint.leftWrist,
        .rightWrist: Joint.rightWrist,
        .leftHip: Joint.leftHip,
        .rightHip: Joint.rightHip,
        .leftKnee: Joint.leftKnee,
        .rightKnee: Joint.rightKnee,
        .leftAnkle: Joint.leftAnkle,
        .rightAnkle: Joint.rightAnkle,
    ]

    private func handle(pixelBuffer: CVPixelBuffer, timestampMs: Int64) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([poseRequest])
        } catch {
            // 单帧失败直接丢弃，不影响后续帧
            return
        }

        let observations = (poseRequest.results ?? []).compactMap { $0 as? VNHumanBodyPoseObservation }

        var pixels = [Landmark](repeating: Landmark(), count: Joint.count)
        var normalized = [Landmark](repeating: Landmark(), count: Joint.count)

        if let person = observations.first,
           let points = try? person.recognizedPoints(.all) {
            let fw = Float(width)
            let fh = Float(height)
            for (name, index) in Self.jointIndex {
                guard let p = points[name] else { continue }
                // Vision 原点在左下、y 向上 → 翻成左上原点、y 向下
                let nx = Float(p.location.x)
                let ny = Float(1.0 - p.location.y)
                let confidence = Float(p.confidence)
                normalized[index] = Landmark(nx, ny, confidence)
                pixels[index] = Landmark(nx * fw, ny * fh, confidence)
            }
        }

        let result = judge.onFrame(
            lms: pixels,
            ts: timestampMs,
            norm: normalized,
            frameW: width,
            frameH: height
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = result
            if result.done, !self.hasFinished {
                self.hasFinished = true
                self.onCompleted?()
            }
        }
    }

    /// 供安全阀使用：相机启动后是否曾经识别到过人
    func notePersonDetected() -> Bool {
        !snapshot.landmarks.isEmpty
    }
}

// MARK: - 视频帧回调

extension CameraPoseController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestampMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        handle(pixelBuffer: pixelBuffer, timestampMs: timestampMs)
    }
}

// MARK: - 相机预览视图

/// 用 `AVCaptureVideoPreviewLayer` 做底层，配合骨骼叠加画在同一坐标系里。
struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let conn = view.previewLayer.connection, conn.isVideoMirroringSupported {
            // 前置摄像头镜像显示，照镜子更符合直觉；叠加层会同步做水平翻转
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass 已固定为该类型，安全
        layer as! AVCaptureVideoPreviewLayer
    }
}
