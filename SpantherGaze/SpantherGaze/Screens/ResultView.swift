import SwiftUI

struct ResultView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        // Landscape: the numbers on the left, the buttons on the right, so it fits in 390 pt of height.
        HStack(spacing: 28) {
            VStack(spacing: 14) {
                Text(L("Калибровка готова")).font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                if let r = app.report {
                    HStack(spacing: 10) {
                        stat(r.meanErrorPt, String(format: L("%.2f см · %.1f°"), r.meanErrorCm, r.meanErrorDeg), L("средний промах"))
                            .kineticEntrance(order: 1)
                        stat(r.jitterPt, String(format: L("%.2f см · %.1f°"), r.jitterCm, r.jitterDeg), L("дрожание"))
                            .kineticEntrance(order: 2)
                    }
                    Text(verdict(r)).font(Atlas.body).multilineTextAlignment(.center).foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(zoneText)
                        .font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                Button { app.continueAfterCalibration() } label: { Text(nextTitle) }
                    .buttonStyle(AtlasPrimaryButton())
                Button { app.beginCalibration(then: app.afterCalibration) } label: { Text(L("Откалибровать заново")) }
                    .buttonStyle(AtlasSecondaryButton())
                ShareLink(item: app.logURL) { Label(L("Экспорт CSV"), systemImage: "square.and.arrow.up") }
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.ink)
            }
            .frame(width: 260)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
    }

    /// Where the result leads: back to what asked for the calibration, or to the games after the session's first one.
    private var nextTitle: String {
        switch app.afterCalibration {
        case .rhythm: return L("К ритм-режиму")
        case .winkBeat: return "Wink Beat"
        case .arcade(let g): return g.title
        case .pursuit: return L("К разминке")
        case .probe: return L("К пробе")
        case .game: return L("Играть")
        case .clinic: return L("Дальше")
        default: return L("К играм")
        }
    }

    /// The meteors' hit zone in words (screen pt). With small targets it is the regular zone times the scale. Either
    /// way it is never smaller than the floor the calibration's miss and spread set.
    private var zoneText: String {
        let scale = app.targetScale
        guard scale < 1 else {
            guard app.zoneFloorPt > 0 else { return String(format: L("Зона попадания: радиус метеорита + %.0f pt"), app.hitMarginPt) }
            return String(format: L("Зона попадания: радиус метеорита + %.0f pt, но не меньше %.0f pt"), app.hitMarginPt, app.zoneFloorPt)
        }
        return String(format: L("Мелкие цели: зона попадания %.0f%% от обычной (радиус метеорита + %.0f pt), но не меньше %.0f pt"),
                      scale * 100, app.hitMarginPt, app.zoneFloorPt)
    }

    private func verdict(_ r: AccuracyReport) -> String {
        if r.meanErrorCm <= 1.0 { return L("Отлично: цель для взрослого (1,0 см) достигнута.") }
        if r.meanErrorCm <= 1.5 { return L("Хорошо: в пределах цели для ребёнка (1,5 см).") }
        return app.nightVision
            ? L("Неточно. Без зрачков в темноте так бывает: поднеси телефон чуть ближе и откалибруй заново.")
            : L("Неточно. Попробуй откалибровать заново при хорошем свете.")
    }

    /// One of the check's numbers: it rolls up to its value in screen points, with cm and degrees under it.
    private func stat(_ pt: Double, _ small: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            RollUp(value: pt) { String(format: "%.0f pt", $0) }.foregroundStyle(Atlas.ink)
            Text(small).font(Atlas.caption).monospacedDigit().foregroundStyle(Atlas.ink)
            Text(label).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .atlasPlate(padding: 12)
    }
}
