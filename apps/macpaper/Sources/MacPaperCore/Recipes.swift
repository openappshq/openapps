import Foundation

/// A recipe is a named document: the wallpaper, a name, and the palette
/// it was made with. The library keeps recipes; a `.macpaper` file and a
/// `macpaper://s/` code carry one.
public struct Recipe: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var wallpaper: Wallpaper
    public let addedAt: Date

    public init(id: UUID = UUID(), name: String? = nil, wallpaper: Wallpaper, addedAt: Date = Date()) {
        self.id = id
        self.name = name.map(Recipe.cleanName) ?? Recipe.defaultName(for: wallpaper)
        self.wallpaper = wallpaper
        self.addedAt = addedAt
    }

    /// The palette the document's colors came from, or "Custom".
    public var paletteName: String { Palettes.name(for: wallpaper.generator.colors) }

    /// "<palette> · <generator>": what a recipe is called when nobody
    /// named it (a migrated favorite, a bare share code).
    public static func defaultName(for wallpaper: Wallpaper) -> String {
        "\(Palettes.name(for: wallpaper.generator.colors)) · \(generatorTitle(for: wallpaper))"
    }

    public static func generatorTitle(for wallpaper: Wallpaper) -> String {
        if case .field(let p) = wallpaper.generator { return p.family.title }
        return wallpaper.generator.kind.title
    }

    /// One line, trimmed, at most 80 characters; empty stays empty (the
    /// caller falls back to the default name).
    public static func cleanName(_ name: String) -> String {
        let oneLine = name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(80))
    }

    public static let maxNameLength = 80

    private enum CodingKeys: String, CodingKey { case id, name, wallpaper, addedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wallpaper = try container.decode(Wallpaper.self, forKey: .wallpaper)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: name.flatMap { Recipe.cleanName($0).isEmpty ? nil : $0 },
            wallpaper: wallpaper,
            addedAt: try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        )
    }
}

/// The favorites of earlier versions, by their old name.
public typealias Favorite = Recipe

/// The recipe library, newest first, in `favorites.json` (version 2; a
/// version-1 favorites file migrates, every favorite named
/// "<palette> · <generator>"). A recipe is the document, not a render.
/// Membership is by document content: the same generator, parameters,
/// seed and finishes is the same recipe, whatever it is called. Every
/// change is written before it is reported; a write that fails throws and
/// leaves the list as it was.
public final class RecipeLibrary: @unchecked Sendable {
    private struct File: Codable, Sendable {
        var version = 2
        var recipes: LossyArray<Recipe>
    }

    private struct LegacyFile: Codable, Sendable {
        var version: Int?
        var favorites: LossyArray<Recipe>?
        var recipes: LossyArray<Recipe>?
    }

    private let file: JSONFile<File>
    private let lock = NSLock()
    private var recipes: [Recipe]

    /// Loads the library; a missing file starts with `starters` (the
    /// taste set on a fresh install), written on the first change.
    public init(fileURL: URL, starters: [Recipe] = []) {
        file = JSONFile(url: fileURL)
        if let legacy = try? JSONFile<LegacyFile>(url: fileURL).load() {
            recipes = legacy.recipes?.elements ?? legacy.favorites?.elements ?? []
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            recipes = []
        } else {
            recipes = starters
        }
    }

    public var all: [Recipe] {
        lock.withLock { recipes }
    }

    public func contains(_ wallpaper: Wallpaper) -> Bool {
        lock.withLock { recipes.contains { $0.wallpaper == wallpaper } }
    }

    public func recipe(for wallpaper: Wallpaper) -> Recipe? {
        lock.withLock { recipes.first { $0.wallpaper == wallpaper } }
    }

    /// Adds the document unless it is one already (then renames it when a
    /// name is given); returns the recipe.
    @discardableResult
    public func add(_ wallpaper: Wallpaper, named name: String? = nil, at date: Date = Date()) throws -> Recipe {
        try lock.withLock {
            if let index = recipes.firstIndex(where: { $0.wallpaper == wallpaper }) {
                guard let name, !Recipe.cleanName(name).isEmpty, Recipe.cleanName(name) != recipes[index].name else { return recipes[index] }
                var next = recipes
                next[index].name = Recipe.cleanName(name)
                try file.save(File(recipes: LossyArray(next)))
                recipes = next
                return next[index]
            }
            let recipe = Recipe(name: name.flatMap { Recipe.cleanName($0).isEmpty ? nil : $0 }, wallpaper: wallpaper, addedAt: date)
            var next = recipes
            next.insert(recipe, at: 0)
            try file.save(File(recipes: LossyArray(next)))
            recipes = next
            return recipe
        }
    }

    /// Adds a recipe as it is (an import keeps its name).
    @discardableResult
    public func add(_ recipe: Recipe) throws -> Recipe {
        try add(recipe.wallpaper, named: recipe.name, at: recipe.addedAt)
    }

    public func rename(_ id: UUID, to name: String) throws {
        try lock.withLock {
            guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }
            let clean = Recipe.cleanName(name)
            var next = recipes
            next[index].name = clean.isEmpty ? Recipe.defaultName(for: next[index].wallpaper) : clean
            try file.save(File(recipes: LossyArray(next)))
            recipes = next
        }
    }

    public func remove(_ wallpaper: Wallpaper) throws {
        try lock.withLock {
            let next = recipes.filter { $0.wallpaper != wallpaper }
            guard next.count != recipes.count else { return }
            try file.save(File(recipes: LossyArray(next)))
            recipes = next
        }
    }

    /// Adds when absent, removes when present; returns whether it is in
    /// the library afterwards.
    @discardableResult
    public func toggle(_ wallpaper: Wallpaper) throws -> Bool {
        if contains(wallpaper) {
            try remove(wallpaper)
            return false
        }
        try add(wallpaper)
        return true
    }
}

public typealias FavoritesStore = RecipeLibrary

// MARK: - The recipe document

/// What a `.macpaper` file and a share code hold: a versioned header, the
/// name, the palette's name and the document. JSON:
/// `{"macpaper":1,"kind":"recipe","name":"…","palette":"…","wallpaper":{…}}`.
/// A bare document (the JSON of earlier share codes) is a recipe with the
/// default name.
public struct RecipeDocument: Codable, Hashable, Sendable {
    public static let format = 1
    public static let kind = "recipe"
    /// The file's extension and its type identifier (declared by the app).
    public static let fileExtension = "macpaper"
    public static let typeIdentifier = "space.openapps.macpaper.recipe"

    public var name: String
    public var palette: String
    public var wallpaper: Wallpaper

    public init(name: String? = nil, palette: String? = nil, wallpaper: Wallpaper) {
        let clean = name.map(Recipe.cleanName) ?? ""
        self.name = clean.isEmpty ? Recipe.defaultName(for: wallpaper) : clean
        self.palette = palette.map(Recipe.cleanName).flatMap { $0.isEmpty ? nil : $0 } ?? Palettes.name(for: wallpaper.generator.colors)
        self.wallpaper = wallpaper
    }

    public init(_ recipe: Recipe) {
        self.init(name: recipe.name, palette: recipe.paletteName, wallpaper: recipe.wallpaper)
    }

    public var recipe: Recipe { Recipe(name: name, wallpaper: wallpaper) }

    private enum CodingKeys: String, CodingKey { case macpaper, kind, name, palette, wallpaper }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let format = try container.decodeIfPresent(Int.self, forKey: .macpaper) {
            guard format <= Self.format else {
                throw DecodingError.dataCorruptedError(forKey: .macpaper, in: container, debugDescription: "Recipe format \(format) is newer than \(Self.format)")
            }
            let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Self.kind
            guard kind == Self.kind else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Not a recipe: \(kind)")
            }
            self.init(
                name: try container.decodeIfPresent(String.self, forKey: .name),
                palette: try container.decodeIfPresent(String.self, forKey: .palette),
                wallpaper: try container.decode(Wallpaper.self, forKey: .wallpaper)
            )
        } else {
            // A bare document.
            self.init(wallpaper: try Wallpaper(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.format, forKey: .macpaper)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(palette, forKey: .palette)
        try container.encode(wallpaper, forKey: .wallpaper)
    }

    /// Stable key order, no whitespace: the share code's bytes.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The `.macpaper` file: the same JSON, pretty-printed.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Decodes a file or a code's JSON, bounded like a share code: the
    /// same size limit, the same refusals for a document that does not
    /// decode.
    public static func decode(_ data: Data) throws -> RecipeDocument {
        guard data.count <= ShareCode.maxDocumentBytes else { throw ShareCode.DecodeError.tooLong }
        do {
            return try JSONDecoder().decode(RecipeDocument.self, from: data)
        } catch {
            throw ShareCode.DecodeError.corrupt
        }
    }

    /// The file name a recipe exports as.
    public var fileName: String {
        let safe = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { out, char in
            if char == "-", out.last == "-" { return }
            out.append(char)
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(safe.isEmpty ? "macPaper" : safe).\(Self.fileExtension)"
    }
}
