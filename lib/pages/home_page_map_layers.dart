part of 'home_page.dart';

class _HomePageMapLayers {
  static Widget buildMapMoodOverlay() {
    return const SizedBox.shrink();
  }

  static Widget buildTopSearchBar(_HomePageState state) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(232),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withAlpha(145), width: 1),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: TypeAheadField<Map<String, dynamic>>(
            builder: (context, controller, focusNode) {
              state._searchController.value = controller.value;
              return TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  hintText: "Search destination",
                  hintStyle: TextStyle(
                    color: Colors.blueGrey.shade400,
                    fontSize: 14,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: _HomePageState._accentColor,
                  ),
                  suffixIcon: state._destinationPos != null
                      ? IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          onPressed: state._clearRoute,
                        )
                      : const Icon(
                          Icons.place_outlined,
                          color: Colors.blueGrey,
                        ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 15),
                ),
              );
            },
            suggestionsCallback: (pattern) async =>
                await state._getSearchSuggestions(pattern),
            itemBuilder: (context, suggestion) => ListTile(
              leading: const Icon(
                Icons.pin_drop_outlined,
                color: _HomePageState._accentColor,
                size: 18,
              ),
              title: Text(
                suggestion['display_name'] ?? "Unknown",
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            onSelected: (suggestion) async {
              await state._applySuggestionSelection(suggestion);
            },
          ),
        ),
      ),
    );
  }
}
