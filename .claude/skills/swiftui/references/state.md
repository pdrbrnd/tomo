# State Management

The decision framework for state. Targets a modern Swift environment which means the Observation framework (`@Observable`) is the default, not `ObservableObject`.

## The Decision Tree

1. **Is it derived from other state?** Make it a computed property. Don't store it.
2. **Does only one view read and mutate it?** `@State` on that view.
3. **Do parent and child both need to read/mutate it?** `@State` on the parent, `@Binding` to the child.
4. **Does it outlive the view (DB connection, file watcher, long-lived service)?** `@Observable` class. Store with `@State` on the highest view that owns it; pass to children via `@Bindable` (mutable) or property (read-only).
5. **Do many unrelated views need it (settings, current document)?** Same as (4), but inject via `.environment` instead of passing through every view.

That's the whole framework. If you're reaching for something else, stop and reconsider.

## `@State` for Value Types

`@State` is the default for view-local state. Works for `Bool`, `Int`, `String`, structs, arrays of structs.

```swift
struct SearchField: View {
    @State private var query = ""

    var body: some View {
        TextField("Search", text: $query)
    }
}
```

`@State` also owns `@Observable` class instances. This replaces `@StateObject` (which was for `ObservableObject`):

```swift
struct AppWindow: View {
    @State private var store = Store()  // owns the instance

    var body: some View {
        ContentView(store: store)
    }
}
```

The view owns it. When the view goes away, so does the instance.

## `@Observable` for Reference Types

Use when state is genuinely shared, expensive to recreate, or owns external resources.

```swift
@Observable
final class Store {
    var items: [Item] = []
    var isLoading = false

    private let api: API

    init(api: API) {
        self.api = api
    }

    func load() async throws {
        isLoading = true
        defer { isLoading = false }
        items = try await api.fetchAll()
    }
}
```

No `@Published`. No `ObservableObject` conformance. Properties are observed automatically by views that read them.

`final` is the default for `@Observable` classes — they're not designed to be subclassed and `final` improves performance.

## `@Bindable` for Mutable Bindings

When a child view needs to mutate properties of an `@Observable` instance:

```swift
struct EditView: View {
    @Bindable var item: Item  // Item is @Observable

    var body: some View {
        TextField("Name", text: $item.name)
    }
}
```

`@Bindable` on the parameter is what enables `$item.name`. Without it, you can read but not bind.

## Environment for Cross-Cutting State

Things many unrelated views need:

```swift
// Define a key
extension EnvironmentValues {
    @Entry var store: Store = Store.preview
}

// Provide at the top
ContentView()
    .environment(\.store, store)

// Read in any descendant
struct ItemList: View {
    @Environment(\.store) var store
    // ...
}
```

The `@Entry` macro (Swift 5.9+) replaces the older `EnvironmentKey` boilerplate.

## What Not To Do

### Don't use `ObservableObject` + `@Published`

```swift
// ❌ Pre-Observation pattern
class Store: ObservableObject {
    @Published var items: [Item] = []
}

// ✅ Modern pattern
@Observable
final class Store {
    var items: [Item] = []
}
```

`ObservableObject` still compiles. Don't write new code with it.

### Don't use `@StateObject`/`@ObservedObject`/`@EnvironmentObject`

These are the old API tied to `ObservableObject`. The new equivalents:

| Old | New |
| --- | --- |
| `@StateObject var x = Foo()` | `@State var x = Foo()` (where `Foo` is `@Observable`) |
| `@ObservedObject var x: Foo` | `var x: Foo` (read-only) or `@Bindable var x: Foo` (mutable) |
| `@EnvironmentObject var x: Foo` | `@Environment(\.foo) var x: Foo` |

### Don't store derived state

```swift
// ❌ Two sources of truth, will drift
@Observable
final class Store {
    var items: [Item] = []
    var itemCount: Int = 0   // updated when items changes — until it isn't

    func add(_ item: Item) {
        items.append(item)
        itemCount = items.count   // easy to forget
    }
}

// ✅ One source, derive the rest
@Observable
final class Store {
    var items: [Item] = []
    var itemCount: Int { items.count }
}
```

This generalises: filtered lists, sorted lists, formatted strings, computed badges. Compute, don't store.

### Don't sync state with `onChange`

```swift
// ❌ Sync pattern
@State private var items: [Item] = []
@State private var filtered: [Item] = []

var body: some View {
    SearchField(text: $query)
        .onChange(of: query) { filtered = items.filter { ... } }
}

// ✅ Derive
@State private var items: [Item] = []
@State private var query = ""

var filtered: [Item] {
    query.isEmpty ? items : items.filter { ... }
}
```

`onChange` is for side effects (logging, persisting), not for keeping two pieces of state in sync.

### Don't reach for view models reflexively

A view model is appropriate when:

- The view has multiple async operations with intertwined state
- The same state and behaviour is genuinely needed by multiple views
- There's testable logic that benefits from isolation from the view

For most views (display a list, show a detail, edit a field), you don't need one. SwiftUI views *are* the view layer. Adding a `*ViewModel` that mirrors the view's properties is duplication.

When you do need shared logic, it usually belongs in a domain layer (plain Swift, fully testable, no SwiftUI imports), not in a `*ViewModel` class.

## Worked Examples

### List window with search

```swift
struct ListWindow: View {
    @Environment(\.store) var store: Store
    @State private var selection: Item?
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            ItemList(
                items: filtered,
                selection: $selection
            )
        } detail: {
            if let item = selection {
                ItemDetail(item: item)
            }
        }
        .searchable(text: $query)
    }

    private var filtered: [Item] {
        query.isEmpty
            ? store.items
            : store.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
```

`store` is shared across the app, so it's in the environment. `selection` and `query` are window-local, so they're `@State`. `filtered` is derived, so it's computed.

### App-wide settings

```swift
@Observable
final class Settings {
    var preferredFolder: URL?
    var notificationEmail: String = ""
    var enabledFeatures: Set<String> = []

    // Persisted via UserDefaults; load/save in init/didSet
}
```

Shared, mutated from many places, lives for the app's lifetime. `@Observable` class, injected via environment.

### Pure view-local

```swift
struct SearchField: View {
    @State private var query = ""
    let onSubmit: (String) -> Void

    var body: some View {
        TextField("Search", text: $query)
            .onSubmit { onSubmit(query) }
    }
}
```

Pure view-local state. Closure callback up. No view model needed.
