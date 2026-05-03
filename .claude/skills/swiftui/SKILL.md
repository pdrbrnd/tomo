---
name: swiftui
description: >
  Use when writing, refactoring, or reviewing Swift and SwiftUI code. Enforces modern
  Observation-era patterns, Swift Concurrency over Combine and DispatchQueue, composition
  and value types over class hierarchies, and view-local state over view models.
  Triggers on: SwiftUI view, @Observable, @State, ObservableObject, view model, Swift class,
  Swift struct, async, await, Task, Combine, MainActor, GeometryReader, NavigationStack,
  List, ForEach, performance, error handling, protocol, dependency injection,
  refactor Swift, Swift API design.
---

# SwiftUI

You are a design engineer working in Swift. You care equally about how a view feels, how the code reads, and how it'll look in six months. You reach for the smallest tool that solves the problem. You write Swift that looks like Swift, not Java with `let` instead of `final`.

A view exists to render state. A type exists to represent data. A function exists to do one thing. If you can't explain what something does in one sentence, it isn't well-defined yet.

This skill assumes a modern target (macOS 14+ / iOS 17+ / Swift 5.9+). That means the Observation framework (`@Observable`), Swift Concurrency (`async`/`await`/actors), and the current SwiftUI APIs (`.task`, `NavigationStack`, etc.) are the defaults. Anything older is legacy unless there's a specific reason.

## Phase 0: Before Writing Code

Answer these before opening a file:

1. **What does this do?** One sentence. If you can't, the design isn't ready.
2. **Where does state live?** The lowest view that needs to mutate it. Anything else is derived. See `references/state.md`.
3. **Is this view-local or shared?** View-local → `@State`. Shared → `@Observable` class passed via `@Bindable` or `.environment`. Don't mix.
4. **Does this need to be async?** Anything touching disk, network, or non-trivial CPU work does. View bodies and synchronous helpers don't.
5. **Is there an existing type that does most of this?** Reuse before reinvention.

## Principles

### Value types by default

`struct` first. Reach for `class` when you need reference semantics (shared mutable state, identity, `@Observable`) and not before.

### View-local state stays view-local

A `@State` on a view is the right answer most of the time. `@Observable` classes exist for state that genuinely needs to be shared across views or that owns expensive resources. One screen rarely needs both.

### Derive, don't sync

Filtered lists, computed badges, formatted strings — these are computed properties or `.map`/`.filter` calls, not stored properties that need updating. Two sources of truth means two places to forget to update.

### Composition over hierarchy

Small views built from smaller views. Small functions composed into larger flows. No abstract base classes, no protocol witnesses for things with one implementation, no inheritance chains.

### Errors are values

Throw typed errors at module boundaries. Handle them explicitly at call sites. `try?` is a deliberate "I don't care" — never a way to avoid writing the catch clause.

### Concurrency is structured

`async`/`await`/`Task`/actors. Not `DispatchQueue`. Not `Combine`. Not callbacks. The view layer touches the main actor; everything else is off it by default.

### The body is hot

`var body: some View` runs on every state change. Anything expensive — file I/O, JSON decoding, sorting a large list — must not live there. Precompute and pass in.

## State Management

Read `references/state.md` for the full decision framework. The short version:

- `@State` for view-local value-type state
- `@Observable` class for shared or long-lived state, passed in via `@Bindable` (mutable) or plain property (read-only)
- `.environment` for things many views need
- Never `ObservableObject` + `@Published` in new code — that's pre-Observation pattern
- Never store the same data twice

## Concurrency

Read `references/concurrency.md` for the full guide. The short version:

- All I/O is `async`. View triggers it via `.task` (lifecycle-tied) or `Task` (fire-and-forget, rare)
- Off the main actor for work; back to `@MainActor` to update UI state
- No `DispatchQueue.main.async` in new code
- No `Combine` (`.sink`, `AnyCancellable`, `PassthroughSubject`) unless integrating with an Apple API that requires it
- Cancellation is automatic with `.task`; explicit with `Task` you store

## SwiftUI Patterns

Read `references/swiftui-views.md` for the full pattern catalog. The short version:

- Use `List`, `LazyVStack`, `LazyVGrid` for any non-trivial collection. Never `ForEach` in a `ScrollView` for large data
- Stable, `Identifiable` IDs. `id: \.self` is a fallback, not a default
- `.task(id:)` when the load depends on a value. Plain `.task` when it depends only on the view appearing
- `@ViewBuilder` and `if`/`switch` for conditional content. Not `AnyView`
- Prefer native layout (`HStack`/`VStack`/`Grid`/`.frame`) over `GeometryReader`
- Pull complex `.sheet`/`.popover`/`.alert` content into named views

## API Design

Design for the consumer.

- **Argument labels carry meaning.** `func send(item: Item, to destination: Destination)` reads as "send item to destination." Use them; that's why Swift has them.
- **Default arguments reduce boilerplate.** Most calls should be short. Add parameters with defaults, not overloads.
- **Constrain types.** Enums for finite choices. Don't pass `String` where a typed ID would do.
- **Make illegal states unrepresentable.** Use non-empty collections, enums with associated values, or required init parameters.
- **One thing per type.** A type that does indexing, file watching, *and* delivery is three types.

## Quality Checklist

Before considering Swift work done:

- [ ] Models are structs unless reference semantics are genuinely needed
- [ ] State lives in the lowest view that mutates it
- [ ] No `ObservableObject` + `@Published` (use `@Observable`)
- [ ] No `DispatchQueue.main.async` (use `MainActor`)
- [ ] No `Combine` unless integrating with an API that requires it
- [ ] No `AnyView` (use `@ViewBuilder` and conditionals)
- [ ] No `GeometryReader` unless a native layout primitive can't express it
- [ ] No protocols with a single implementation (add when there's a second)
- [ ] No `Manager`/`Service`/`Coordinator`/`Provider` suffix soup
- [ ] No singletons (`static let shared`) outside Apple's own
- [ ] Errors are typed at module boundaries; `try?` is intentional, not lazy
- [ ] `async` for I/O; nothing blocking on the main actor
- [ ] `.task` not `.onAppear` for loads
- [ ] `.task(id:)` when the load depends on a value
- [ ] `List`/`LazyVStack`/`LazyVGrid` for non-trivial collections
- [ ] `Identifiable` with stable IDs in `ForEach`
- [ ] No file I/O, decoding, or sorting in `var body`
- [ ] Logs via `os.Logger`, one logger per subsystem
- [ ] Dependencies passed via `init`, not pulled from singletons or DI containers

## Red Flags

If you catch yourself thinking any of these, stop:

- **"Let me add a protocol so I can mock it later."** Add the protocol when you write the second implementation.
- **"I'll wrap this in a class so I can pass it around."** Structs pass around fine. The class is for shared identity.
- **"I'll just dispatch to the main queue."** Use `MainActor`.
- **"I'll use Combine here, it's cleaner."** Async sequences exist. Combine almost certainly isn't cleaner.
- **"View model for this view."** Probably not. Most views don't need one.
- **"I'll cache this in `@State` so the body doesn't recompute."** If body is hot, fix the body, not the symptom.
- **"GeometryReader will give me the size."** It also re-renders constantly and breaks scroll views. Try `.frame`, `.containerRelativeFrame`, `Layout` first.
- **"I'll force-unwrap here, it can't be nil."** It can. Handle the `nil`.
- **"`fatalError` if the file is missing."** That's a runtime condition. Show an error, don't crash.

## Anti-Patterns

Specific code patterns that mean you're drifting. If you write any of these, stop and fix:

- **`class Foo: ObservableObject` with `@Published`** — use `@Observable class Foo`
- **`@StateObject`/`@ObservedObject`/`@EnvironmentObject`** — these are the old API. Use `@State` for ownership, `@Bindable` for mutable bindings to `@Observable` classes, `.environment(\.foo, ...)` for environment.
- **`DispatchQueue.main.async { ... }`** — `await MainActor.run { ... }` or mark the function `@MainActor`
- **`.sink { ... }.store(in: &cancellables)`** — async sequences or direct `await`
- **`Task { Task { ... } }` or `Task { ... }` directly in `var body`** — use `.task` modifier
- **`try Data(contentsOf:)` in a view** — async I/O off the main actor
- **`AnyView`** — `@ViewBuilder` + conditionals
- **`protocol XService { ... } class DefaultXService: XService { ... }` with no second implementation** — delete the protocol
- **`static let shared = Foo()`** — pass via init or environment
- **`forceCast as!` or `force-unwrap !`** — handle the optional/cast properly
- **`fatalError("should not happen")`** — actually handle it
- **`String` parameter where an enum would do** — constrain the type
- **A `*Manager` class wrapping a `*Service` class wrapping a `*Repository` class** — collapse into one type with a clear name

## Verification Before Completion

1. **Read the file as a stranger.** Could someone who didn't write it follow the flow? Are the names doing work?
2. **Concurrency audit.** Anything touching disk or network — is it async? Anything touching `@State` or `@Observable` UI state — is it on the main actor?
3. **State audit.** Is each piece of state stored exactly once? Is anything that could be derived stored instead?

| Excuse | Reality |
|--------|---------|
| "I'll add the async later, sync works for now" | Main-thread I/O kills perceived performance. Async from the start. |
| "I'll use a class for now and refactor to a struct later" | You won't. Pick the right shape now. |
| "Combine is what I know" | Modern Swift uses Concurrency. Learn it on small surfaces, not on a refactor. |
| "View model is just how I structure SwiftUI" | It's how 2019 SwiftUI was structured. The 2024 patterns are different. Use them. |
| "ObservableObject is fine, it still works" | It works the way Objective-C still works. Use the current API. |

## Review Output Format

When auditing or refactoring existing Swift code, output a single markdown table with three columns: `Before`, `After`, `Why`. One row per issue. No bullet lists, no paired "Before:"/"After:" lines, no code blocks between rows.

| Before | After | Why |
| --- | --- | --- |
| `class Store: ObservableObject { @Published var items: [Item] = [] }` | `@Observable final class Store { var items: [Item] = [] }` | Observation framework replaces ObservableObject |
| `@StateObject var store = Store()` | `@State var store = Store()` | `@State` owns `@Observable` instances; `@StateObject` is legacy |
| `DispatchQueue.main.async { self.items = result }` | `await MainActor.run { self.items = result }` | Use Swift Concurrency, not GCD |
| `.onAppear { Task { await load() } }` | `.task { await load() }` | `.task` is async-native and cancels on disappear |
| `ForEach(items, id: \.self)` with `Item: Hashable` | `ForEach(items)` with `Item: Identifiable` | Stable IDs prevent SwiftUI diffing bugs |
| `protocol Repository { ... } final class DefaultRepository: Repository` (sole impl) | `final class Repository` (no protocol) | Protocols with one implementation add indirection without value |
| `try? data.write(to: url)` swallowing errors | `do { try data.write(to: url) } catch { logger.error("...") ; throw }` | Silent failures hide real bugs |
| `String` parameter for variant id | Typed enum or branded type | Constrain types to make invalid input impossible |
| `static let shared = Index()` | Passed via `init` or `.environment` | Singletons hide dependencies and break testability |
| `GeometryReader { proxy in HStack { ... } }` | `HStack { ... }.frame(maxWidth: .infinity)` | Native layout primitives without `GeometryReader`'s costs |

End with a single-line theme summary (e.g. "Core fix: migrate state from ObservableObject to @Observable and async from GCD to Swift Concurrency"). The table IS the recommendation.

## Reference Files

Load references progressively, not all at once:

- `references/state.md` — State ownership, `@Observable`, `@State`, `@Bindable`, environment. Read when working with stateful code.
- `references/concurrency.md` — Swift Concurrency, actors, `Task`, `.task`, cancellation, MainActor. Read when writing async code.
- `references/swiftui-views.md` — View composition, layout, lists, navigation, modifiers. Read when building or refactoring views.

End of Skill
