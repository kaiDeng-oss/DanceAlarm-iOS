import SwiftUI

/// 骨骼叠加：把主要骨架画在相机预览上，让用户一眼看出自己有没有全身入镜。
///
/// 坐标换算与安卓版一致：按 `resizeAspectFill` 的方式把「正立画幅」铺满整个视图，
/// 再按需做一次水平翻转来对齐前置摄像头的镜像预览。
struct SkeletonOverlay: View {

    let snapshot: DanceSnapshot?
    let mirror: Bool

    /// 骨架连线（关键点索引成对出现）
    private static let bones: [Int] = [
        Joint.leftShoulder, Joint.rightShoulder,
        Joint.leftShoulder, Joint.leftElbow,
        Joint.leftElbow, Joint.leftWrist,
        Joint.rightShoulder, Joint.rightElbow,
        Joint.rightElbow, Joint.rightWrist,
        Joint.leftShoulder, Joint.leftHip,
        Joint.rightShoulder, Joint.rightHip,
        Joint.leftHip, Joint.rightHip,
        Joint.leftHip, Joint.leftKnee,
        Joint.leftKnee, Joint.leftAnkle,
        Joint.rightHip, Joint.rightKnee,
        Joint.rightKnee, Joint.rightAnkle,
        Joint.nose, Joint.leftShoulder,
        Joint.nose, Joint.rightShoulder,
    ]

    var body: some View {
        Canvas { context, size in
            guard let s = snapshot,
                  !s.landmarks.isEmpty,
                  s.frameW > 0,
                  s.frameH > 0 else { return }

            let viewW = size.width
            let viewH = size.height
            let frameW = CGFloat(s.frameW)
            let frameH = CGFloat(s.frameH)
            let scale = max(viewW / frameW, viewH / frameH)
            let offsetX = (viewW - frameW * scale) / 2
            let offsetY = (viewH - frameH * scale) / 2

            func point(_ index: Int) -> CGPoint? {
                guard index < s.landmarks.count else { return nil }
                let landmark = s.landmarks[index]
                guard landmark.visibility >= 0.25 else { return nil }
                var x = offsetX + CGFloat(landmark.x) * frameW * scale
                let y = offsetY + CGFloat(landmark.y) * frameH * scale
                if mirror { x = viewW - x }
                return CGPoint(x: x, y: y)
            }

            let tint = s.phase.tint

            var i = 0
            while i + 1 < Self.bones.count {
                if let a = point(Self.bones[i]), let b = point(Self.bones[i + 1]) {
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(
                        path,
                        with: .color(tint),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                }
                i += 2
            }

            for index in s.landmarks.indices {
                guard let p = point(index) else { continue }
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)),
                    with: .color(.white.opacity(0.9))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                    with: .color(tint)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
