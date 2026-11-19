import AppKit
import SwiftUI

/// Estado de carga de la lista de un `SearchablePickerPopover`.
enum PickerLoadState: Equatable {
    case loading
    case loaded
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Botón que abre un popover con buscador y lista filtrable.
///
/// - `.single`: elegir una fila cierra el popover.
/// - `.multiple`: cada fila es un checkbox y el popover queda abierto.
///
/// Teclado: ↑/↓ mueven la selección, Return elige o marca, Esc cierra.
struct SearchablePickerPopover<Item: Identifiable, TriggerLabel: View>: View {
    enum SelectionMode { case single, multiple }

    enum TriggerStyle {
        /// Botón estándar de macOS.
        case button
        /// El label (p. ej. chips con sus propios botones) a la izquierda y, a la derecha, un botón estándar con
        /// `title` y un chevron que abre el popover (así se puede enfocar con el teclado).
        case accessory(title: String)
    }

    /// Fila extra "Agregar «texto»" para valores que no están en la lista.
    /// `submit` devuelve un mensaje de error para mostrar en línea, o nil si salió bien.
    struct Freeform {
        let title: (String) -> String
        let submit: (String) async -> String?
    }

    let mode: SelectionMode
    let items: [Item]
    let loadState: PickerLoadState
    let triggerStyle: TriggerStyle
    let placeholder: String
    let width: CGFloat
    let title: (Item) -> String
    let subtitle: ((Item) -> String?)?
    let avatar: ((Item) -> AnyView)?
    let section: ((Item) -> String)?
    let isSelected: (Item) -> Bool
    let isDisabled: (Item) -> Bool
    let freeform: Freeform?
    let onRetry: (() -> Void)?
    let onReload: (() -> Void)?
    let onPick: (Item) -> Void
    let label: () -> TriggerLabel

    @State private var isPresented = false

    init(
        mode: SelectionMode,
        items: [Item],
        loadState: PickerLoadState = .loaded,
        triggerStyle: TriggerStyle = .button,
        placeholder: String = "Search…",
        width: CGFloat = 320,
        title: @escaping (Item) -> String,
        subtitle: ((Item) -> String?)? = nil,
        avatar: ((Item) -> AnyView)? = nil,
        section: ((Item) -> String)? = nil,
        isSelected: @escaping (Item) -> Bool = { _ in false },
        isDisabled: @escaping (Item) -> Bool = { _ in false },
        freeform: Freeform? = nil,
        onRetry: (() -> Void)? = nil,
        onReload: (() -> Void)? = nil,
        onPick: @escaping (Item) -> Void,
        @ViewBuilder label: @escaping () -> TriggerLabel
    ) {
        self.mode = mode
        self.items = items
        self.loadState = loadState
        self.triggerStyle = triggerStyle
        self.placeholder = placeholder
        self.width = width
        self.title = title
        self.subtitle = subtitle
        self.avatar = avatar
        self.section = section
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.freeform = freeform
        self.onRetry = onRetry
        self.onReload = onReload
        self.onPick = onPick
        self.label = label
    }

    var body: some View {
        switch triggerStyle {
        case .button:
            Button { isPresented.toggle() } label: { label() }
                .popover(isPresented: $isPresented, arrowEdge: .bottom) { popoverContent }
        case .accessory(let title):
            HStack(alignment: .center, spacing: 8) {
                label().frame(maxWidth: .infinity, alignment: .leading)
                Button { isPresented.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .popover(isPresented: $isPresented, arrowEdge: .bottom) { popoverContent }
            }
        }
    }

    private var popoverContent: some View {
        PickerContent(picker: self, close: { isPresented = false })
    }
}

// MARK: - Contenido del popover

private struct PickerContent<Item: Identifiable, TriggerLabel: View>: View {
    let picker: SearchablePickerPopover<Item, TriggerLabel>
    let close: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @State private var freeformBusy = false
    @State private var freeformError: String?
    @State private var listHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

    private static var maxListHeight: CGFloat { 320 }

    /// Una fila navegable: un item o la fila "Agregar «texto»".
    private enum Row {
        case item(Item)
        case freeform(String)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [Item] {
        let text = trimmedQuery.lowercased()
        guard !text.isEmpty else { return picker.items }
        return picker.items.filter { item in
            picker.title(item).lowercased().contains(text)
                || (picker.subtitle?(item)?.lowercased().contains(text) ?? false)
        }
    }

    /// Los items filtrados agrupados en secciones consecutivas (sin `section`, una sola sin título).
    private var sections: [(title: String?, items: [Item])] {
        guard let section = picker.section else { return [(nil, filtered)] }
        var result: [(title: String?, items: [Item])] = []
        for item in filtered {
            let key = section(item)
            if let last = result.last, last.title == key {
                result[result.count - 1].items.append(item)
            } else {
                result.append((key, [item]))
            }
        }
        return result
    }

    private var freeformText: String? {
        guard picker.freeform != nil, !trimmedQuery.isEmpty else { return nil }
        let exact = picker.items.contains { picker.title($0).lowercased() == trimmedQuery.lowercased() }
        return exact ? nil : trimmedQuery
    }

    private var rows: [Row] {
        let flat = sections.flatMap(\.items).map(Row.item)
        return flat + (freeformText.map { [Row.freeform($0)] } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            if let onReload = picker.onReload {
                Divider()
                HStack {
                    Text(countLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload", action: onReload)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .disabled(picker.loadState == .loading)
                        .help("Fetch the list from GitHub again")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(width: picker.width)
        .background(KeyMonitor(onKey: handleKey))
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in
            highlighted = 0
            freeformError = nil
        }
    }

    private var countLabel: String {
        let count = picker.items.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(picker.placeholder, text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                IconButton(systemImage: "xmark.circle.fill", help: "Clear Search", size: 11) { query = "" }
            }
        }
        .font(.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch picker.loadState {
        case .loading where picker.items.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 80)
        case .failed(let message) where picker.items.isEmpty:
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.redText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRetry = picker.onRetry {
                    Button("Try Again", action: onRetry)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 80)
        default:
            if rows.isEmpty {
                Text("No Results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    let allRows = rows
                    let offsets = sectionOffsets
                    ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, group in
                        Section {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                let rowIndex = offsets[sectionIndex] + index
                                itemRow(item, highlighted: rowIndex == highlighted)
                                    .id(rowIndex)
                                    .onHover { if $0 { highlighted = rowIndex } }
                            }
                        } header: {
                            if let title = group.title {
                                Text(title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    if case .freeform(let text) = allRows.last {
                        let rowIndex = allRows.count - 1
                        freeformRow(text, highlighted: rowIndex == highlighted)
                            .id(rowIndex)
                            .onHover { if $0 { highlighted = rowIndex } }
                    }
                }
                .padding(4)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ListHeightKey.self, value: geometry.size.height)
                })
            }
            .frame(height: min(max(listHeight, 32), Self.maxListHeight))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            .onChange(of: highlighted) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    private var sectionOffsets: [Int] {
        var offsets: [Int] = []
        var running = 0
        for group in sections {
            offsets.append(running)
            running += group.items.count
        }
        return offsets
    }

    private func itemRow(_ item: Item, highlighted: Bool) -> some View {
        let selected = picker.isSelected(item)
        let disabled = picker.isDisabled(item)
        return Button { pick(item) } label: {
            HStack(spacing: 8) {
                if picker.mode == .multiple {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                }
                if let avatar = picker.avatar { avatar(item) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(picker.title(item)).font(.body).lineLimit(1).truncationMode(.middle)
                    if let subtitle = picker.subtitle?(item), !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if picker.mode == .single && (selected || disabled) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(highlighted: highlighted && !disabled))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func freeformRow(_ text: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { submitFreeform(text) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                    Text(picker.freeform?.title(text) ?? text).font(.body).lineLimit(1)
                    Spacer(minLength: 4)
                    if freeformBusy { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowBackground(highlighted: highlighted))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(freeformBusy)
            if let freeformError {
                Text(freeformError)
                    .font(.subheadline)
                    .foregroundStyle(Theme.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func rowBackground(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            .fill(highlighted ? Theme.accent.opacity(0.14) : .clear)
    }

    // MARK: Acciones

    private func pick(_ item: Item) {
        guard !picker.isDisabled(item) else { return }
        picker.onPick(item)
        if picker.mode == .single { close() }
    }

    private func submitFreeform(_ text: String) {
        guard let freeform = picker.freeform, !freeformBusy else { return }
        freeformBusy = true
        freeformError = nil
        Task {
            let error = await freeform.submit(text)
            freeformBusy = false
            if let error {
                freeformError = error
            } else {
                query = ""
                if picker.mode == .single { close() }
            }
        }
    }

    private func handleKey(_ key: KeyMonitor.Key) -> Bool {
        let rows = self.rows
        switch key {
        case .down:
            guard !rows.isEmpty else { return true }
            highlighted = min(highlighted + 1, rows.count - 1)
            return true
        case .up:
            highlighted = max(highlighted - 1, 0)
            return true
        case .return:
            guard rows.indices.contains(highlighted) else { return true }
            switch rows[highlighted] {
            case .item(let item): pick(item)
            case .freeform(let text): submitFreeform(text)
            }
            return true
        case .escape:
            close()
            return true
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Teclado

/// Escucha ↑ ↓ Return y Esc en la ventana del popover mientras la vista está montada.
/// El `TextField` enfocado se comería las flechas antes que `onKeyPress`, por eso un monitor local.
private struct KeyMonitor: NSViewRepresentable {
    enum Key { case up, down, `return`, escape }

    let onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onKey = onKey
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var view: NSView?
        var onKey: ((Key) -> Bool)?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window else { return event }
                let key: Key? = switch event.keyCode {
                case 125: .down
                case 126: .up
                case 36, 76: .return
                case 53: .escape
                default: nil
                }
                guard let key, let onKey = self.onKey, onKey(key) else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
