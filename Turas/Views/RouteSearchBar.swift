import SwiftUI

/// Expandable search bar with direction picker for filtering vehicles by route.
///
/// Three collapsed states, following `viewModel.selection`:
/// 1. idle → "Search routes" pill
/// 2. route → route name + direction buttons
/// 3. route + direction → "39A > To UCD" with star and clear buttons
struct RouteSearchBar: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var favourites: FavouritesStore
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            modeTabs

            VStack(spacing: 0) {
                if viewModel.isSearchActive {
                    expandedSearchView
                } else {
                    switch viewModel.selection {
                    case .idle:
                        collapsedView
                    case .route:
                        directionPickerView
                    case .routeAndDirection:
                        activeFilterView
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The selected route's name, with its operator when two agencies share it.
    private var selectedRouteTitle: String {
        guard let name = viewModel.selectedRouteName else { return "" }
        guard viewModel.isAmbiguous(name), let route = viewModel.selectedTransitRoute else { return name }
        return "\(name) · \(route.operatorLabel)"
    }

    private var selectedRouteAccessibilityName: String {
        guard let name = viewModel.selectedRouteName else { return "" }
        let operatorName = viewModel.isAmbiguous(name) ? viewModel.selectedTransitRoute?.operatorLabel : nil
        return AccessibilityText.route(name: name, operatorName: operatorName)
    }

    // MARK: - Mode tabs

    private var modeTabs: some View {
        HStack(spacing: 6) {
            ForEach(TransportMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.selectMode(mode)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.iconName)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(mode.label)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        viewModel.selectedMode == mode
                            ? mode.color
                            : Color.secondary.opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(
                        viewModel.selectedMode == mode ? .white : .primary
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label)
                .accessibilityHint("Shows \(mode.label.lowercased()) routes")
                .accessibilityAddTraits(viewModel.selectedMode == mode ? .isSelected : [])
            }
            Spacer()
        }
    }

    // MARK: - State 1: No filter — "Search routes"

    private var collapsedView: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.isSearchActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Search routes")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - State 2: Route selected — direction picker

    private var directionPickerView: some View {
        VStack(spacing: 8) {
            HStack {
                Text(selectedRouteTitle)
                    .fontWeight(.semibold)
                    .accessibilityLabel(selectedRouteAccessibilityName)
                Spacer()
                clearButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            VStack(spacing: 6) {
                ForEach(viewModel.directionOptions) { option in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.selectDirection(option.direction)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right")
                                .foregroundStyle(viewModel.activeRouteColor)
                                .accessibilityHidden(true)
                            Text(option.title)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityHint("Shows stops and vehicles in this direction")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - State 3: Route + direction — active filter

    private var activeFilterView: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.clearDirection()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedRouteTitle)
                        .fontWeight(.semibold)
                    if let option = selectedDirectionOption {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(option.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel([selectedRouteAccessibilityName, selectedDirectionOption?.title]
                .compactMap { $0 }
                .joined(separator: ", "))
            .accessibilityHint("Choose a different direction")

            Spacer()

            starButton

            clearButton
        }
        .padding(12)
    }

    private var selectedDirectionOption: DirectionOption? {
        guard let direction = viewModel.selectedDirection else { return nil }
        return viewModel.directionOptions.first { $0.direction == direction }
    }

    /// Read through `favourites` (observed) so the star updates when toggled.
    private var isSelectionStarred: Bool {
        guard let entry = viewModel.selectionAsSavedRoute else { return false }
        return favourites.isStarred(entry)
    }

    private var starButton: some View {
        let isStarred = isSelectionStarred
        return Button {
            viewModel.toggleStarForSelection()
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStarred ? "Remove from starred routes" : "Add to starred routes")
        .accessibilityAddTraits(isStarred ? .isSelected : [])
    }

    private var clearButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.clearSearch()
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear route")
    }

    // MARK: - Expanded search

    private var expandedSearchView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(viewModel.selectedMode.searchPlaceholder, text: $viewModel.searchText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.submitSearch()
                        }
                    }
                    .accessibilityLabel("Search \(viewModel.selectedMode.label.lowercased()) routes")

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search text")
                }

                Button("Done") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isTextFieldFocused = false
                        viewModel.submitSearch()
                    }
                }
                .fontWeight(.medium)
            }
            .padding(12)

            if viewModel.searchText.isEmpty {
                savedRoutesRow(title: "Starred", entries: favourites.starred(for: viewModel.selectedMode))
                savedRoutesRow(title: "Recent", entries: favourites.recents(for: viewModel.selectedMode))
            }

            if !viewModel.availableRoutes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.availableRoutes.prefix(20)) { route in
                            routeChip(route)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func routeChip(_ route: TransitRoute) -> some View {
        let isSelected = route.ref == viewModel.selectedRoute
        let operatorName = viewModel.isAmbiguous(route.name) ? route.operatorLabel : nil
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.selectRoute(route)
                isTextFieldFocused = false
            }
        } label: {
            VStack(spacing: 0) {
                Text(route.name)
                    .font(.subheadline.weight(.medium))
                if let operatorName {
                    Text(operatorName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? viewModel.selectedMode.routeColor(for: route.name)
                    : Color.secondary.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AccessibilityText.route(name: route.name, operatorName: operatorName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Starred and recent routes

    @ViewBuilder
    private func savedRoutesRow(title: String, entries: [SavedRoute]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entries) { entry in
                            savedRouteChip(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    private func savedRouteChip(_ entry: SavedRoute) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                isTextFieldFocused = false
                viewModel.selectSaved(entry)
            }
        } label: {
            HStack(spacing: 4) {
                Text(entry.route.name)
                    .font(.subheadline.weight(.medium))
                if let agencyName = entry.agencyName {
                    Text(agencyName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(viewModel.selectedMode.routeColor(for: entry.route.name).opacity(0.2), in: Capsule())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AccessibilityText.route(name: entry.route.name, operatorName: entry.agencyName))
    }
}
