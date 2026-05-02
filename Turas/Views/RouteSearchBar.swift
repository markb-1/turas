import SwiftUI

/// Expandable search bar with direction picker for filtering buses by route.
///
/// Three collapsed states:
/// 1. No filter → "Search routes" pill
/// 2. Route selected, no direction → route name + direction buttons
/// 3. Route + direction selected → "39A > To UCD" with clear button
struct RouteSearchBar: View {
    @ObservedObject var viewModel: MapViewModel
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            modeTabs

            VStack(spacing: 0) {
                if viewModel.isSearchActive {
                    expandedSearchView
                } else if !viewModel.searchText.isEmpty && viewModel.selectedDirection == nil {
                    directionPickerView
                } else if !viewModel.searchText.isEmpty && viewModel.selectedDirection != nil {
                    activeFilterView
                } else {
                    collapsedView
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                Text(viewModel.searchText)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.clearSearch()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            VStack(spacing: 6) {
                ForEach(viewModel.directionLabels, id: \.direction) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.selectDirection(item.direction)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right")
                                .foregroundStyle(viewModel.activeRouteColor)
                            Text("To \(item.label)")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
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
                    Text(viewModel.searchText)
                        .fontWeight(.semibold)
                    if let dir = viewModel.selectedDirection,
                       let label = viewModel.directionLabels.first(where: { $0.direction == dir })?.label {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("To \(label)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.clearSearch()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Expanded search

    private var expandedSearchView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(viewModel.selectedMode.searchPlaceholder, text: $viewModel.searchText)
                    .textInputAutocapitalization(.characters)
                    .focused($isTextFieldFocused)

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Done") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isTextFieldFocused = false
                        viewModel.isSearchActive = false
                    }
                }
                .fontWeight(.medium)
            }
            .padding(12)

            if !viewModel.availableRoutes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.availableRoutes.prefix(20), id: \.self) { route in
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    viewModel.selectRoute(route)
                                    isTextFieldFocused = false
                                }
                            } label: {
                                Text(route)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        route == viewModel.searchText
                                            ? viewModel.selectedMode.routeColor(for: route)
                                            : Color.secondary.opacity(0.15),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(
                                        route == viewModel.searchText ? .white : .primary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}
