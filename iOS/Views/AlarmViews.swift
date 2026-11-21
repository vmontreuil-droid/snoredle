import SwiftUI

/// Wekkerkaart op het startscherm.
struct AlarmCard: View {
    @EnvironmentObject var settings: AppSettings
    @State private var permissionDenied = false

    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: settings.alarmMinutes / 60, minute: settings.alarmMinutes % 60,
                                      second: 0, of: .now) ?? .now
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                settings.alarmMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(settings.alarmEnabled ? Theme.accent.opacity(0.18) : .white.opacity(0.06))
                        Image(systemName: settings.alarmEnabled ? "alarm.fill" : "alarm")
                            .foregroundStyle(settings.alarmEnabled ? Theme.accent : .secondary)
                    }.frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wekker").font(.subheadline.weight(.semibold))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Wekker", isOn: Binding(get: { settings.alarmEnabled }, set: { on in
                        settings.alarmEnabled = on
                        if on { Task { permissionDenied = !(await AlarmService.shared.requestPermission()) } }
                    }))
                    .labelsHidden().tint(Theme.accent)
                }
                if settings.alarmEnabled {
                    HStack {
                        DatePicker("Wektijd", selection: time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                        Spacer()
                        Picker("Slim venster", selection: $settings.smartWindowMinutes) {
                            Text("Exact").tag(0)
                            Text("Slim 10′").tag(10)
                            Text("Slim 20′").tag(20)
                            Text("Slim 30′").tag(30)
                        }
                        .pickerStyle(.menu).tint(Theme.accent)
                    }
                    if permissionDenied {
                        Label("Geef Snoredle toegang tot wekkers in Instellingen › Snoredle.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .animation(.snappy, value: settings.alarmEnabled)
    }

    private var subtitle: String {
        guard settings.alarmEnabled else { return "Uit — tik om in te stellen" }
        let end = String(format: "%02d:%02d", settings.alarmMinutes / 60, settings.alarmMinutes % 60)
        if settings.smartWindowMinutes == 0 { return "Gaat af om \(end), ook in stille modus" }
        let s = (settings.alarmMinutes - settings.smartWindowMinutes + 1440) % 1440
        return "Wekt je licht slapend tussen \(String(format: "%02d:%02d", s / 60, s % 60)) en \(end)"
    }
}

/// Volledig scherm als de eigen alarmtoon afgaat (iOS ouder dan 26).
struct AlarmRingingView: View {
    @ObservedObject var alarm = AlarmService.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.45), Color(red: 0.98, green: 0.55, blue: 0.35),
                                    Color(red: 0.35, green: 0.25, blue: 0.45)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "sun.horizon.fill").font(.system(size: 80))
                    .symbolEffect(.pulse)
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 76, weight: .thin, design: .rounded)).monospacedDigit()
                Text("Goedemorgen").font(.system(.title, design: .rounded).weight(.semibold))
                Spacer()
                Button { alarm.dismiss() } label: {
                    Text("Stop en bekijk mijn nacht").font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .background(.white, in: Capsule()).foregroundStyle(.black)
                }
                Button { alarm.snooze() } label: {
                    Label("Sluimer \(AppSettings.shared.snoozeMinutes) min", systemImage: "zzz")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                        .background(.white.opacity(0.25), in: Capsule()).foregroundStyle(.white)
                }
                Spacer().frame(height: 20)
            }
            .padding(28)
            .foregroundStyle(.white)
        }
    }
}
