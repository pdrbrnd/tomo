# SwiftUI Views

Patterns for composing views, laying them out, and avoiding the common traps.

## View Composition

A view is small. If it grows past one screen, split it.

```swift
// ❌ Big view, hard to read
struct DetailView: View {
    let item: Item
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let image = item.image { /* 20 lines */ }
                    VStack { /* 30 lines of metadata */ }
                }
                Divider()
                /* 40 lines of related items and actions */
                Divider()
                /* 30 lines of secondary UI */
            }
        }
    }
}

// ✅ Composed
struct DetailView: View {
    let item: Item
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ItemHeader(item: item)
                Divider()
                ItemActions(item: item)
                Divider()
                ItemSecondary(item: item)
            }
        }
    }
}
```

Each sub-view is its own file when it has its own state or is reused. Inline (private struct in the same file) when it's just a structural break.

## Layout

Reach for these in order:

1. `HStack`/`VStack`/`ZStack` — 90% of cases
2. `Grid`/`LazyVGrid`/`LazyHGrid` — actual grids
3. `.frame`, `.fixedSize`, `.layoutPriority` — sizing
4. `Spacer`, `.padding` — spacing
5. `Layout` protocol — custom layouts when none of the above fit
6. `GeometryReader` — last resort

`GeometryReader` re-renders constantly and breaks scroll views. If you find yourself reaching for it, ask whether `.containerRelativeFrame`, `.frame(maxWidth: .infinity)`, or `Layout` would do.

### Don't put external margin on a view

```swift
// ❌ Component decides its own outer spacing
struct Row: View {
    var body: some View {
        HStack { /* ... */ }
            .padding(.bottom, 12)  // baked-in
    }
}

// ✅ Parent controls spacing with VStack/spacing or .padding
VStack(spacing: 12) {
    ForEach(items) { Row(item: $0) }
}
```

The component shouldn't decide where it sits. The parent does, with `spacing:` on a stack or `.padding` on the parent.

## Lists and Collections

### Use `List` for non-trivial collections

`List` is lazy by default, has built-in selection, supports `.searchable`, integrates with `NavigationSplitView`.

```swift
List(items, selection: $selection) { item in
    ItemRow(item: item)
}
```

### `LazyVStack` / `LazyVGrid` for custom-styled lists

When `List`'s built-in chrome is wrong (a poster grid, a custom card layout):

```swift
ScrollView {
    LazyVGrid(columns: gridColumns, spacing: 16) {
        ForEach(items) { item in
            ItemCard(item: item)
        }
    }
}
```

### Don't `ForEach` inside `ScrollView` for large data

```swift
// ❌ Renders everything at once, slow with 1000+ items
ScrollView {
    VStack {
        ForEach(items) { ItemCard(item: $0) }
    }
}

// ✅ Only renders visible cells
ScrollView {
    LazyVStack {
        ForEach(items) { ItemCard(item: $0) }
    }
}
```

### Stable IDs

Make your model `Identifiable` and use the implicit id.

```swift
// ✅ Implicit id from Identifiable
ForEach(items) { item in /* ... */ }

// ⚠️ Fallback when the type isn't Identifiable
ForEach(strings, id: \.self) { /* ... */ }
```

`id: \.self` works for `Hashable` types but is fragile — if two values are equal, SwiftUI gets confused. Prefer `Identifiable`.

## Conditional Content

### `@ViewBuilder` and `if`

```swift
@ViewBuilder
var body: some View {
    if let item = selection {
        DetailView(item: item)
    } else {
        Text("Select an item")
    }
}
```

`some View` doesn't normally allow conditionals, but `@ViewBuilder` (which is implicit on `body`) does.

### `switch` for finite states

```swift
@ViewBuilder
private var content: some View {
    switch loadState {
    case .idle: EmptyView()
    case .loading: ProgressView()
    case .loaded(let items): ItemList(items: items)
    case .failed(let error): ErrorView(error: error)
    }
}
```

### Don't use `AnyView`

```swift
// ❌ Type erasure, performance cost
func itemView(for item: Item) -> AnyView {
    if item.isAvailable {
        return AnyView(ItemCard(item: item))
    } else {
        return AnyView(ItemPlaceholder())
    }
}

// ✅ @ViewBuilder
@ViewBuilder
func itemView(for item: Item) -> some View {
    if item.isAvailable {
        ItemCard(item: item)
    } else {
        ItemPlaceholder()
    }
}
```

`AnyView` defeats SwiftUI's diffing. Only use it when the view type genuinely can't be known at compile time, which is rare.

## Modifiers

### Order matters

```swift
Text("Hello")
    .padding()           // adds padding
    .background(.red)    // background fills the padded area

Text("Hello")
    .background(.red)    // background fills just the text
    .padding()           // padding outside the red background
```

When something looks wrong, check modifier order before assuming the modifier is buggy.

### Pull complex sheet content into a view

```swift
// ❌ Inline complex content
.sheet(isPresented: $editing) {
    VStack {
        TextField(...)
        TextField(...)
        HStack { /* 30 more lines */ }
    }
}

// ✅ Named view
.sheet(isPresented: $editing) {
    EditSheet(item: $item)
}
```

The sheet closure should look like a single function call.

### Modifier soup belongs in `ViewModifier`

If the same chain of 5+ modifiers appears in multiple places:

```swift
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(radius: 2)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}
```

Don't pre-emptively extract — wait for the second use.

## Navigation

### `NavigationSplitView` for sidebar/detail apps

Classic Mac sidebar/list/detail layout:

```swift
NavigationSplitView {
    Sidebar(selection: $selectedSection)
} content: {
    ItemList(items: items, selection: $selected)
} detail: {
    if let item = selected {
        DetailView(item: item)
    } else {
        ContentUnavailableView("Select an item", systemImage: "doc")
    }
}
```

### `NavigationStack` for push/pop flows

If a settings panel grows multiple levels:

```swift
NavigationStack(path: $path) {
    SettingsRoot()
        .navigationDestination(for: SettingsPage.self) { page in
            switch page {
            case .general: GeneralSettings()
            case .advanced: AdvancedSettings()
            }
        }
}
```

`NavigationLink` pushes onto the path. `path.removeLast()` or setting it to `[]` pops.

### Avoid `NavigationView`

Deprecated. Use `NavigationStack` or `NavigationSplitView`.

## Performance

### `var body` is hot

It runs on every state change that affects the view. Don't put expensive work there.

```swift
// ❌ Sorts on every render
var body: some View {
    let sorted = items.sorted { $0.name < $1.name }
    return List(sorted) { /* ... */ }
}

// ✅ Sort once, use the result
var body: some View {
    List(sortedItems) { /* ... */ }
}

private var sortedItems: [Item] {
    items.sorted { $0.name < $1.name }
}
```

For genuinely expensive computation that depends on state, compute it once in the model layer and store the result.

### Identity vs structure

When SwiftUI re-renders a view, it diffs by identity. If identity is stable, state is preserved. If identity changes, the view is destroyed and rebuilt.

```swift
// ❌ Different conditions = different identity
if condition {
    ItemList(items: items)
} else {
    ItemList(items: items)  // different identity from above branch
}

// ✅ Same identity, different content
ItemList(items: condition ? itemsA : itemsB)
```

This rarely matters but is worth knowing when state mysteriously resets.

### Large views: split into smaller ones

A view that re-evaluates because *anything* in its scope changed will re-render its whole body. Splitting into sub-views means each sub-view only re-evaluates when its own inputs change.

```swift
// ❌ Whole view re-renders when search query changes
var body: some View {
    VStack {
        SearchField(text: $query)
        Divider()
        Text(complexHeader)  // recomputes on every keystroke
        ItemList(items: filtered)
    }
}

// ✅ Header is its own view, only renders when its inputs change
var body: some View {
    VStack {
        SearchField(text: $query)
        Divider()
        Header()  // separate view, separate re-render scope
        ItemList(items: filtered)
    }
}
```

## Accessibility

These are minimums; more is better.

- All interactive elements have a clear text label (system buttons get one for free; custom ones need `.accessibilityLabel`)
- Focus states are visible (SwiftUI default usually works; check on Tab navigation)
- Images have descriptive labels or are marked decorative
- Dynamic Type works (use system fonts, avoid fixed sizes)
- Colour isn't the only signal (a red border *and* an icon, not just red)

```swift
Button {
    delete(item)
} label: {
    Image(systemName: "trash")
}
.accessibilityLabel("Delete item")
```

## Common Patterns

### Empty / loading / error / loaded

Every view that shows data needs all four states.

```swift
@ViewBuilder
var body: some View {
    switch state {
    case .idle, .loading:
        ProgressView()
    case .loaded(let items) where items.isEmpty:
        ContentUnavailableView(
            "Nothing here yet",
            systemImage: "doc",
            description: Text("Add your first item to get started.")
        )
    case .loaded(let items):
        ItemList(items: items)
    case .failed(let error):
        ContentUnavailableView(
            "Couldn't load",
            systemImage: "exclamationmark.triangle",
            description: Text(error.localizedDescription)
        )
    }
}
```

`ContentUnavailableView` is the right tool for empty and error states.

### Drag and drop import

```swift
.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
    Task {
        for provider in providers {
            guard let url = try? await provider.loadFileURL() else { continue }
            try? await importer.import(url)
        }
    }
    return true
}
.overlay(isDropTargeted ? DropHighlight() : nil)
```

### Keyboard shortcuts

Mac apps live and die by these. Use `.keyboardShortcut` on buttons:

```swift
Button("Send") { /* ... */ }
    .keyboardShortcut("k", modifiers: [.command])
```

For app-wide shortcuts, use the `Commands` API at the `App` level.

### Window vs. sheet vs. popover

- **Window** for primary surfaces
- **Sheet** for modal forms that are contained but substantial (edit, settings)
- **Popover** for compact, transient UI (a quick action menu)
- **Inspector** (`.inspector`) for detail panels alongside main content

Don't reach for sheet when an inspector or detail pane is right there.
