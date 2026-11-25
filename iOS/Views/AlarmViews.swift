import SwiftUI

/// Wekkerkaart op het startscherm: eerstvolgende wekker + toegang tot de lijst.
struct AlarmCard: View {
    @ObservedObject var alarms = AlarmService.shared
    @State private var showList = false

    var body: some View {
        Button { showList = true } label: {
            GlassCard {
                HStack(spacing: 12) {
                    let next = alarms.nextItem
                    ZStack {
                        Circle().fill(next != nil ? Theme.accent.opacity(0.18) : .white.opacity(0.06))
                        Image(systemName: next != nil ? "alarm.fill" : "alarm")
                            .foregroundStyle(next != nil ? Theme.accent : .secondary)
                    }.frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wekkers").font(.subheadline.weight(.semibold))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let (item, date) = next {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(item.timeText).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                            Text(dayWord(date)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showList) { AlarmsView() }
    }

    private var subtitle: String {
        let on = alarms.alarms.filter(\.enabled).count
        if alarms.alarms.isEmpty { return "Tik om een wekker te zetten" }
        if on == 0 { return "Alle wekkers staan uit" }
        if let (_, date) = alarms.nextItem {
            let goal = AppSettings.shared.sleepGoalHours
            let bed = date.addingTimeInterval(-(goal * 3600) - 15 * 60)
            return "Ga slapen rond \(bed.formatted(date: .omitted, time: .shortened)) voor \(String(format: "%.1f", goal)) u slaap"
        }
        return "\(on) actief"
    }

    private func dayWord(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "vandaag" }
        if cal.isDateInTomorrow(d) { return "morgen" }
        return d.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "nl_BE")))
    }
}

/// Lijst met alle wekkers.
struct AlarmsView: View {
    @ObservedObject var service = AlarmService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AlarmItem?
    @State private var testMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Toestemming", systemImage: "checkmark.shield")
                        Spacer()
                        Text(service.permissionText).font(.footnote)
                            .foregroundStyle(service.permissionDenied ? .orange : .secondary)
                    }
                    if service.permissionDenied {
                        Button("Open Instellingen") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                    Button {
                        Task { testMessage = await service.testAlarm() }
                    } label: { Label("Test wekker (over 1 minuut)", systemImage: "alarm.waves.left.and.right") }
                    Button {
                        Task { testMessage = await service.testSmartWake() }
                    } label: { Label("Test slimme wekker (15 s)", systemImage: "sparkles") }
                    if let testMessage { Text(testMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowBackground(Color.white.opacity(0.05))
                ForEach(service.alarms) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.timeText).font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                                .foregroundStyle(a.enabled ? .primary : .secondary)
                            HStack(spacing: 6) {
                                if !a.label.isEmpty { Text(a.label) }
                                Text(a.daysText)
                                if a.smart { Label("Slim \(a.smartWindow)′", systemImage: "sparkles").foregroundStyle(Theme.accent) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Aan", isOn: Binding(get: { a.enabled }, set: { service.setEnabled(a, $0) }))
                            .labelsHidden().tint(Theme.accent)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = a }
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .onDelete { idx in idx.map { service.alarms[$0] }.forEach(service.delete) }

                if service.alarms.isEmpty {
                    Text("Nog geen wekkers. Tik op + om er een te zetten.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle("Wekkers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Klaar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = AlarmItem(minutes: service.alarms.last.map { ($0.minutes + 15) % 1440 } ?? 7 * 60) } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { a in AlarmEditor(item: a, isNew: !service.alarms.contains { $0.id == a.id }) }
            .task { _ = await service.requestPermission() }
        }
    }
}

/// Eén wekker instellen.
struct AlarmEditor: View {
    @State var item: AlarmItem
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: .now) ?? .now },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                item.minutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Tijd", selection: time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .frame(maxWidth: .infinity)

                Section("Herhalen") {
                    HStack(spacing: 6) {
                        ForEach(AlarmItem.dayOrder, id: \.self) { d in
                            let on = item.days.contains(d)
                            Button {
                                if on { item.days.remove(d) } else { item.days.insert(d) }
                            } label: {
                                Text(AlarmItem.shortNames[d] ?? "")
                                    .font(.footnote.weight(.semibold))
                                    .frame(width: 38, height: 38)
                                    .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)), in: Circle())
                                    .foregroundStyle(on ? Theme.night : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    HStack {
                        Button("Werkdagen") { item.days = [2, 3, 4, 5, 6] }
                        Spacer()
                        Button("Weekend") { item.days = [1, 7] }
                        Spacer()
                        Button("Elke dag") { item.days = [] }
                    }
                    .font(.footnote).buttonStyle(.borderless)
                    Text(item.daysText).font(.caption).foregroundStyle(.secondary)
                }

                Section("Naam") {
                    TextField("bv. Werk, Reservewekker", text: $item.label)
                }

                Section {
                    Toggle("Slimme wekker", isOn: $item.smart).tint(Theme.accent)
                    if item.smart {
                        Picker("Venster", selection: $item.smartWindow) {
                            Text("10 min").tag(10); Text("20 min").tag(20); Text("30 min").tag(30); Text("45 min").tag(45)
                        }
                    }
                } footer: {
                    Text(item.smart
                         ? "Tijdens een meting wekt Snoredle je tot \(item.smartWindow) min vroeger, op een moment dat je licht slaapt (je beweegt). Anders gaat hij af om \(item.timeText)."
                         : "Gaat precies om \(item.timeText) af, ook in stille modus.")
                }

                if !isNew {
                    Section {
                        Button("Wekker verwijderen", role: .destructive) {
                            AlarmService.shared.delete(item); dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Nieuwe wekker" : "Wekker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bewaar") { item.enabled = true; AlarmService.shared.upsert(item); dismiss() }.fontWeight(.semibold)
                }
            }
        }
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
