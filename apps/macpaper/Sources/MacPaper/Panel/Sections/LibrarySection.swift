import MacPaperCore
import SwiftUI

/// Library: a name and Save for the current look, Import and Export as
/// `.macpaper` files, then the saved recipes (the favorites, with names;
/// on a fresh install the taste set's starters). A recipe is the whole
/// document; clicking one loads it, and live apply takes it to the
/// desktop; a row drags out as a `.macpaper` file, and one dropped on
/// the column is imported. The list is lazy: it can hold many recipes,
/// and only the rows in the column's scroll viewport are built.
struct LibrarySection: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var seeded = false
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s16) {
            HStack(spacing: Brand.Space.s8) {
                if previewRendering {
                    // The field is AppKit-backed and draws nothing under `ImageRenderer`.
                    Text(name.isEmpty ? model.recipeTitle : name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panelField()
                } else {
                    TextField("Name this look", text: $name)
                        .panelField()
                        .onSubmit { save() }
                        .accessibilityLabel("Recipe name")
                }
                Button("Save") { save() }
                    .buttonStyle(PanelPrimaryButtonStyle())
                    .disabled(model.license.restriction() != nil && !model.isFavorite)
                    .help("Keep the look on the desktop as a recipe")
            }
            Text("A recipe is the whole document: generator, palette, seed, base and finishes. It renders again on any display.")
                .font(Brand.body(11))
                .foregroundStyle(Brand.Panel.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.Space.s8) {
                Button("Import…") { Task { await model.importRecipe() } }
                    .buttonStyle(PanelSecondaryButtonStyle())
                    .help("Open a .macpaper recipe file into the library")
                Button("Export…") { Task { await model.exportRecipe() } }
                    .buttonStyle(PanelSecondaryButtonStyle())
                    .help("Save the look on the desktop as a .macpaper recipe file")
            }
            if model.favoriteList.isEmpty {
                Text("Nothing saved yet.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.Panel.textSecondary)
                    .padding(.vertical, Brand.Space.s8)
            } else {
                PanelList(rendering: previewRendering) {
                    ForEach(model.favoriteList) { favorite in
                        RecipeRow(model: model, favorite: favorite)
                        if favorite.id != model.favoriteList.last?.id {
                            Rectangle().fill(Brand.Panel.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !seeded {
                name = model.recipeTitle
                seeded = true
            }
        }
        .onChange(of: model.recipeTitle) { _, next in
            name = next
        }
    }

    private func save() {
        model.saveRecipe(named: name)
    }
}

/// One saved recipe: thumbnail, title and what it is, the star, and the
/// menu with everything else. Separate sibling controls, never nested
/// (design/components.md).
private struct RecipeRow: View {
    let model: AppModel
    let favorite: Favorite
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            Button {
                model.load(favorite)
            } label: {
                HStack(spacing: Brand.Space.s12) {
                    DocumentThumbnail(model: model, wallpaper: favorite.wallpaper, selected: favorite.wallpaper == model.draft)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(favorite.name)
                            .font(Brand.body(13, weight: 600))
                            .foregroundStyle(Brand.Panel.textPrimary)
                            .lineLimit(1)
                        Text(favorite.subtitle)
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.Panel.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(favorite.name), \(favorite.subtitle)")
            .accessibilityHint("Loads the recipe and applies it")
            .help("Load \(favorite.name)")
            .onDrag {
                // The recipe as a `.macpaper` file.
                guard let url = model.recipeDragURL(for: favorite) else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            }
            Button {
                model.removeFavorite(favorite)
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.Panel.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from the library")
            .help("Remove from the library")
            Menu {
                Button("Apply") { model.load(favorite) }
                Button("Copy link") { model.shareLink(for: favorite.wallpaper) }
                Button("Rename…") { renaming = true }
                Section("Export") {
                    ForEach(ExportKind.allCases, id: \.self) { kind in
                        Button("Export as \(kind.title)") { model.export(kind, of: favorite.wallpaper) }
                    }
                }
                Divider()
                Button("Never show this") { model.neverShow(favorite) }
                Button("Remove") { model.removeFavorite(favorite) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.Panel.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("More: apply, share, rename, export, never show, remove")
        }
        .frame(height: PanelLayout.listRowHeight)
        .alert("Rename recipe", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.rename(favorite, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: renaming) { _, on in if on { newName = favorite.name } }
    }
}

extension Recipe {
    /// "Moiré · seed 42": under the name.
    var subtitle: String {
        var parts = [Recipe.generatorTitle(for: wallpaper), "seed \(wallpaper.seedText)"]
        if !wallpaper.pair.isStill { parts.append(wallpaper.pair.title) }
        return parts.joined(separator: " · ")
    }
}
