import Foundation

/// 单个关键点。x/y 为像素坐标，visibility 为可信度 0...1
struct Landmark {
    var x: Float
    var y: Float
    var visibility: Float

    init(_ x: Float = 0, _ y: Float = 0, _ visibility: Float = 0) {
        self.x = x
        self.y = y
        self.visibility = visibility
    }
}

enum DancePhase {
    case noPerson
    case halfBody
    case phoneShaking
    case tooStill
    case dancing
}

/// 一帧的判定结果。landmarks 已归一化到「正立画幅」的 [0,1] 坐标系，可直接用于叠加绘制。
struct DanceSnapshot {
    var phase: DancePhase
    var hint: String
    var progressMs: Int64
    var requiredMs: Int64
    var intensity: Float
    var amplitude: Float
    var activeJoints: Int
    var beatHz: Float
    var landmarks: [Landmark]
    var frameW: Int
    var frameH: Int

    var progress: Float {
        guard requiredMs > 0 else { return 1 }
        return min(max(Float(progressMs) / Float(requiredMs), 0), 1)
    }

    var done: Bool { progressMs >= requiredMs }

    var remainingSec: Int {
        max(Int((requiredMs - progressMs) / 1000), 0)
    }

    static func initial(requiredMs: Int64, hint: String = "正在启动摄像头…") -> DanceSnapshot {
        DanceSnapshot(
            phase: .noPerson,
            hint: hint,
            progressMs: 0,
            requiredMs: requiredMs,
            intensity: 0,
            amplitude: 0,
            activeJoints: 0,
            beatHz: 0,
            landmarks: [],
            frameW: 1,
            frameH: 1
        )
    }
}

/// 关键点索引。刻意沿用安卓版 ML Kit 的编号（0 与 11...22），
/// 空白编号留作占位，这样两端源码可以逐行对照，排查问题时省事。
enum Joint {
    static let nose = 0
    static let leftShoulder = 11
    static let rightShoulder = 12
    static let leftElbow = 13
    static let rightElbow = 14
    static let leftWrist = 15
    static let rightWrist = 16
    static let leftHip = 17
    static let rightHip = 18
    static let leftKnee = 19
    static let rightKnee = 20
    static let leftAnkle = 21
    static let rightAnkle = 22

    /// 关键点数组长度：必须覆盖到最大的编号
    static let count = 23

    static let limb = [13, 14, 15, 16, 19, 20, 21, 22]
    static let body = [0, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]
}

/// 舞蹈判定引擎。
///
/// 核心思路：把姿态关键点全部换算到「以髋部中心为原点、躯干长度为 1」的坐标系里再做比较。
/// 这样一来 ——
///  - 手机离得远/近、人在画面里偏左偏右偏上偏下、手机横竖屏，都不影响判定；
///  - 最关键的是：单纯晃动手机只会让整个人在画面里平移，而躯干坐标系里的相对位置不变，
///    因此「拿着手机抖」在本引擎中几乎不产生运动量，作弊无效，必须真的动身体。
///
/// 判定三个层次：
///  1. 全身入镜：双肩双髋可信 + 13 个关键点可见 9 个以上（腿必须入镜）；
///  2. 动作幅度：8 大关节（双肘双腕双膝双踝）近 1.4 秒窗口内的摆幅，至少 2 个关节摆幅 ≥ 躯干长的 30%，
///     且最大摆幅 ≥ 45%；
///  3. 节奏感：窗口内运动量波峰频率 ≥ 0.6Hz（动作幅度极大时可豁免）。
///
/// 累计计时：只有判定为「正在跳舞」的帧才累加，停下即暂停，达到 requiredMs 才算过关。
///
/// 与安卓版 `DanceJudge.kt` 的阈值完全一致，两个平台判定行为相同。
final class DanceJudge {

    static let defaultRequiredMs: Int64 = 30_000

    // —— 阈值：单位均为「躯干长度」，与分辨率、拍摄距离无关 ——
    private let coreScore: Float = 0.5
    private let limbScore: Float = 0.35
    private let minBodyVisible = 9
    private let minLimbVisible = 5
    private let activeJointAmp: Float = 0.30
    private let minActiveJoints = 2
    private let minPeakAmp: Float = 0.45
    private let bigAmp: Float = 0.95
    private let minBeatHz: Float = 0.6
    private let shakeRaw: Float = 0.055
    private let shakeAmpLimit: Float = 0.30
    private let minTorsoPx: Float = 20

    let requiredMs: Int64
    private let windowFrames: Int

    private var progressMs: Int64 = 0
    private var lastTs: Int64 = 0
    private var lastVec: [Float]?
    private var vecWindow: [[Float]] = []
    private var motionSeries: [Float] = []
    private var motionTs: [Int64] = []
    private var lastRawCenter: (Float, Float)?
    private var shakeEma: Float = 0
    private var smoothIntensity: Float = 0

    init(requiredMs: Int64 = DanceJudge.defaultRequiredMs, windowFrames: Int = 20) {
        self.requiredMs = requiredMs
        self.windowFrames = windowFrames
    }

    func reset() {
        progressMs = 0
        lastTs = 0
        clearMotion()
        shakeEma = 0
        smoothIntensity = 0
    }

    private func clearMotion() {
        lastVec = nil
        vecWindow.removeAll()
        motionSeries.removeAll()
        motionTs.removeAll()
        lastRawCenter = nil
    }

    private func snapshot(
        _ phase: DancePhase,
        _ hint: String,
        amp: Float,
        joints: Int,
        beat: Float,
        frameW: Int,
        frameH: Int,
        normalized: [Landmark]
    ) -> DanceSnapshot {
        DanceSnapshot(
            phase: phase,
            hint: hint,
            progressMs: progressMs,
            requiredMs: requiredMs,
            intensity: min(max(smoothIntensity, 0), 1),
            amplitude: amp,
            activeJoints: joints,
            beatHz: beat,
            landmarks: normalized,
            frameW: frameW,
            frameH: frameH
        )
    }

    private func distance(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> Float {
        let dx = ax - bx
        let dy = ay - by
        return (dx * dx + dy * dy).squareRoot()
    }

    /// - Parameters:
    ///   - lms: 正立画幅下的像素坐标关键点（Vision 输出换算而来）
    ///   - ts: 单调时钟（毫秒）
    ///   - norm: 同一批关键点，已归一化到正立画幅的 [0,1]（供叠加绘制）
    ///   - frameW: 正立画幅宽（供叠加绘制换算宽高比）
    ///   - frameH: 正立画幅高
    func onFrame(
        lms: [Landmark],
        ts: Int64,
        norm: [Landmark]? = nil,
        frameW: Int = 1,
        frameH: Int = 1
    ) -> DanceSnapshot {
        let normalized = norm ?? lms
        let dt: Int64 = lastTs == 0 ? 0 : ts - lastTs
        lastTs = ts

        func vis(_ i: Int) -> Float { i < lms.count ? lms[i].visibility : 0 }

        let coreOk = vis(Joint.leftShoulder) >= coreScore
            && vis(Joint.rightShoulder) >= coreScore
            && vis(Joint.leftHip) >= coreScore
            && vis(Joint.rightHip) >= coreScore
        let bodyVisible = Joint.body.filter { vis($0) >= limbScore }.count
        let limbVisible = Joint.limb.filter { vis($0) >= limbScore }.count

        guard coreOk else {
            clearMotion()
            smoothIntensity *= 0.4
            return snapshot(.noPerson, "站到镜头前，让上半身完整入镜",
                            amp: 0, joints: 0, beat: 0,
                            frameW: frameW, frameH: frameH, normalized: normalized)
        }

        // ---- 躯干坐标系 ----
        let hipX = (lms[Joint.leftHip].x + lms[Joint.rightHip].x) / 2
        let hipY = (lms[Joint.leftHip].y + lms[Joint.rightHip].y) / 2
        let shX = (lms[Joint.leftShoulder].x + lms[Joint.rightShoulder].x) / 2
        let shY = (lms[Joint.leftShoulder].y + lms[Joint.rightShoulder].y) / 2
        let torso = distance(shX, shY, hipX, hipY)

        guard torso >= minTorsoPx else {
            clearMotion()
            smoothIntensity *= 0.4
            return snapshot(.noPerson, "离手机近一点，或者擦一下镜头",
                            amp: 0, joints: 0, beat: 0,
                            frameW: frameW, frameH: frameH, normalized: normalized)
        }

        guard bodyVisible >= minBodyVisible, limbVisible >= minLimbVisible else {
            clearMotion()
            smoothIntensity *= 0.4
            return snapshot(.halfBody, "后退一步，把腿也拍进画面",
                            amp: 0, joints: 0, beat: 0,
                            frameW: frameW, frameH: frameH, normalized: normalized)
        }

        // ---- 整帧位移：用于识别「拿着手机抖」 ----
        let cx = hipX / Float(max(frameW, 1))
        let cy = hipY / Float(max(frameH, 1))
        if let (px, py) = lastRawCenter {
            shakeEma = 0.75 * shakeEma + 0.25 * distance(cx, cy, px, py)
        }
        lastRawCenter = (cx, cy)

        // ---- 当帧身体坐标系下的向量 ----
        var vec = [Float](repeating: 0, count: Joint.limb.count * 2)
        for (k, j) in Joint.limb.enumerated() {
            vec[k * 2] = (lms[j].x - hipX) / torso
            vec[k * 2 + 1] = (lms[j].y - hipY) / torso
        }

        var motion: Float = 0
        if let pv = lastVec, dt >= 20, dt <= 600 {
            var s: Float = 0
            for k in 0..<Joint.limb.count {
                s += distance(vec[k * 2], vec[k * 2 + 1], pv[k * 2], pv[k * 2 + 1])
            }
            motion = s / Float(Joint.limb.count)
        }
        lastVec = vec

        vecWindow.append(vec)
        while vecWindow.count > windowFrames { vecWindow.removeFirst() }
        motionSeries.append(motion)
        motionTs.append(ts)
        while motionSeries.count > windowFrames {
            motionSeries.removeFirst()
            motionTs.removeFirst()
        }

        // ---- 窗口内各关节摆幅 ----
        var amplitudeMax: Float = 0
        var activeJoints = 0
        if vecWindow.count >= 8 {
            for k in 0..<Joint.limb.count {
                var minX = Float.greatestFiniteMagnitude
                var maxX = -Float.greatestFiniteMagnitude
                var minY = Float.greatestFiniteMagnitude
                var maxY = -Float.greatestFiniteMagnitude
                for v in vecWindow {
                    let x = v[k * 2]
                    let y = v[k * 2 + 1]
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                let range = distance(minX, minY, maxX, maxY)
                if range > amplitudeMax { amplitudeMax = range }
                if range >= activeJointAmp { activeJoints += 1 }
            }
        }

        // ---- 节奏：统计运动量波峰 ----
        var peaks = 0
        if motionSeries.count >= 3 {
            for i in 1..<(motionSeries.count - 1) {
                if motionSeries[i] > motionSeries[i - 1]
                    && motionSeries[i] >= motionSeries[i + 1]
                    && motionSeries[i] > 0.035 {
                    peaks += 1
                }
            }
        }
        let spanMs: Int64 = motionTs.count >= 2 ? (motionTs[motionTs.count - 1] - motionTs[0]) : 0
        let spanSec = max(Float(spanMs) / 1000, 0.6)
        let beatHz = Float(peaks) / spanSec

        // ---- 综合判定 ----
        let shaking = shakeEma > shakeRaw && amplitudeMax < shakeAmpLimit
        let movingEnough = amplitudeMax >= minPeakAmp && activeJoints >= minActiveJoints
        let rhythmic = vecWindow.count < 10 || beatHz >= minBeatHz || amplitudeMax >= bigAmp
        let dancing = !shaking && movingEnough && rhythmic

        // ---- 强度平滑（纯展示用） ----
        let instant = min(max(amplitudeMax / 1.2, 0), 1) * 0.6
            + min(max(Float(activeJoints) / 4, 0), 1) * 0.4
        smoothIntensity = smoothIntensity * 0.7 + instant * 0.3

        // ---- 累计计时：只有真正在跳的帧才计时，停下即暂停 ----
        if dancing && dt >= 1 && dt <= 400 {
            progressMs = min(progressMs + min(dt, 120), requiredMs)
        }

        let phase: DancePhase = dancing ? .dancing : (shaking ? .phoneShaking : .tooStill)

        let hint: String
        switch phase {
        case .dancing:
            hint = progressMs >= requiredMs ? "达标！" : "很好，保持这个节奏！"
        case .phoneShaking:
            hint = "别晃手机 —— 要动身体才算数"
        case .tooStill:
            if activeJoints < minActiveJoints {
                hint = "只有 \(activeJoints) 个部位在动，手脚一起甩起来"
            } else if amplitudeMax < minPeakAmp {
                hint = "幅度太小了，再使劲一点"
            } else if !rhythmic {
                hint = "跟上节拍：一、二、一、二"
            } else {
                hint = "继续跳，别停"
            }
        case .halfBody:
            hint = "后退一步，把腿也拍进画面"
        case .noPerson:
            hint = "站到镜头前，让上半身完整入镜"
        }

        return snapshot(phase, hint,
                        amp: amplitudeMax, joints: activeJoints, beat: beatHz,
                        frameW: frameW, frameH: frameH, normalized: normalized)
    }
}
