# Concurrency

Swift Concurrency (`async`/`await`/`Task`/actors) is the model. No `DispatchQueue`. No `Combine`. No callbacks unless wrapping an Apple API that requires them.

## The Mental Model

- **Async functions** can pause and resume. Callers `await` them.
- **The main actor** is where UI state lives. SwiftUI runs there.
- **Other actors and detached tasks** run off the main actor.
- **Tasks** are units of concurrent work. They're created, they run, they finish (or get cancelled).

The shape of most operations:

1. View triggers work (`.task` or button action)
2. Work happens on a background actor (domain services)
3. Result comes back to the main actor to update UI state

## `.task` for View-Driven Loads

`.task` is the right tool for "load data when this view appears."

```swift
struct DetailView: View {
    let id: UUID
    @State private var item: Item?

    var body: some View {
        Group {
            if let item {
                ItemView(item: item)
            } else {
                ProgressView()
            }
        }
        .task {
            item = try? await api.fetch(id: id)
        }
    }
}
```

What `.task` gives you:

- Async-native, no `Task { }` boilerplate
- Cancels automatically when the view disappears
- Re-runs when the view re-appears

### `.task(id:)` when load depends on a value

```swift
.task(id: id) {
    item = try? await api.fetch(id: id)
}
```

The closure re-runs when `id` changes. Without `id:`, the task only runs on first appearance.

### Don't use `.onAppear` for async work

```swift
// ❌ Old pattern, doesn't cancel cleanly
.onAppear {
    Task {
        item = try? await api.fetch(id: id)
    }
}

// ✅ Modern pattern
.task {
    item = try? await api.fetch(id: id)
}
```

`.onAppear { Task { ... } }` creates a detached task that doesn't cancel when the view disappears. Memory leaks and wasted work.

## `Task` for Fire-and-Forget Actions

When the user clicks a button and the work outlives the view interaction:

```swift
Button("Submit") {
    Task {
        do {
            try await api.submit(form)
        } catch {
            logger.error("Submit failed: \(error)")
        }
    }
}
```

This is fine. The task continues even if the view goes away. Use sparingly — most async work should be tied to view lifecycle via `.task`.

If you need to cancel the task later, store it:

```swift
@State private var submitTask: Task<Void, Never>?

Button("Submit") {
    submitTask = Task { try? await api.submit(form) }
}

Button("Cancel") {
    submitTask?.cancel()
}
```

## Main Actor

UI state must be mutated on the main actor. SwiftUI views and their `@State`/`@Observable` properties are main-actor by convention.

When you call back from background work to update UI:

```swift
@Observable
@MainActor
final class Store {
    var items: [Item] = []

    func load() async throws {
        let loaded = try await api.fetchAll()  // off main actor
        items = loaded  // back on main actor automatically (class is @MainActor)
    }
}
```

Marking `@Observable` classes `@MainActor` is the cleanest approach when they're UI-facing state. Their methods can still call `async` work that runs off the main actor — the compiler figures out the hops.

If you have to hop manually:

```swift
// ✅
await MainActor.run {
    items = loaded
}

// ❌ Don't do this in new code
DispatchQueue.main.async {
    items = loaded
}
```

`DispatchQueue` predates Swift Concurrency. Don't mix the two models.

## Off the Main Actor

I/O, parsing, computation — never on the main actor.

```swift
struct Parser {
    func parse(_ url: URL) async throws -> Document {
        // Async function called from main actor will run on main actor
        // unless you explicitly hop or use a non-main actor
        let data = try Data(contentsOf: url)
        return try decode(data)
    }
}
```

Async functions run on whatever actor the caller is on, *unless* they explicitly hop. To force off the main actor:

```swift
struct Parser {
    func parse(_ url: URL) async throws -> Document {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try decode(data)
        }.value
    }
}
```

Or use a non-main actor for the whole subsystem:

```swift
actor FileSystem {
    func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
```

`actor` types serialise their own state and run off the main actor by default. Good fit for "this thing owns disk access."

## Cancellation

`Task` cancellation is cooperative. The task isn't killed; it's *asked* to stop. Long-running work should check:

```swift
func processAll(_ items: [Item]) async throws -> [Result] {
    var results: [Result] = []
    for item in items {
        try Task.checkCancellation()  // throws if cancelled
        results.append(try await process(item))
    }
    return results
}
```

`.task` cancels when the view disappears. If your async work doesn't honour cancellation, it keeps running. For loops, file enumeration, and anything iterative, sprinkle in `try Task.checkCancellation()`.

## What Not To Do

### Don't use Combine

`@Published`, `.sink`, `AnyCancellable`, `PassthroughSubject`, `CurrentValueSubject` — all Combine.

```swift
// ❌ Combine
publisher
    .map { ... }
    .sink { value in ... }
    .store(in: &cancellables)

// ✅ Async sequences (Apple equivalent)
for await value in someAsyncStream {
    // ...
}
```

If you're integrating with an Apple API that exposes a `Publisher`, bridge to async sequences via `.values`:

```swift
for await note in NotificationCenter.default.notifications(named: .NSWindowDidResize).values {
    // ...
}
```

### Don't nest `Task`s in view bodies

```swift
// ❌ Re-creates the task on every body re-evaluation
var body: some View {
    Text("Hello").onAppear {
        Task { await load() }
    }
}

// ✅
var body: some View {
    Text("Hello").task {
        await load()
    }
}
```

### Don't use `Task` at the top of a view body

```swift
// ❌ Fires every time body evaluates — that's many times
var body: some View {
    Task { await load() }
    return Text("Hello")
}
```

Always `.task` for view-driven async.

### Don't block the main thread

```swift
// ❌ Blocks the UI for the duration of the read
struct ImageView: View {
    let url: URL
    var body: some View {
        let data = try! Data(contentsOf: url)  // synchronous I/O
        return Image(nsImage: NSImage(data: data) ?? .init())
    }
}

// ✅
struct ImageView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image) }
            else { ProgressView() }
        }
        .task {
            image = await loadImage(from: url)
        }
    }
}
```

### Don't use callbacks when async/await fits

```swift
// ❌ Callback API
func load(id: UUID, completion: @escaping (Result<Item, Error>) -> Void)

// ✅ Async API
func load(id: UUID) async throws -> Item
```

Wrap callback APIs in `withCheckedThrowingContinuation` if you must, but prefer building async-native interfaces.

## Worked Examples

### Loading on launch

```swift
@main
struct MyApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.store, store)
                .task {
                    do {
                        try await store.load()
                    } catch {
                        logger.error("Initial load failed: \(error)")
                    }
                }
        }
    }
}
```

### Importing on drop

```swift
struct DropZone: View {
    @Environment(\.store) var store
    @State private var importing = false

    var body: some View {
        ContentView()
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                Task {
                    importing = true
                    defer { importing = false }
                    for provider in providers {
                        if let url = try? await provider.loadFileURL() {
                            try? await store.import(url)
                        }
                    }
                }
                return true
            }
    }
}
```

### Background work with progress

```swift
@MainActor
@Observable
final class Importer {
    var items: [Item] = []
    var progress: Double?

    func process(_ urls: [URL]) async throws {
        progress = 0
        defer { progress = nil }

        var found: [Item] = []
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            found.append(try await parse(url))
            progress = Double(i + 1) / Double(urls.count)
        }
        items = found
    }
}
```

The class is `@MainActor`. Its async methods can still hop off (the actual work in `parse` runs on a background actor). Updates to `items` and `progress` happen on the main actor naturally.
