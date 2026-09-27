import 'package:flutter/widgets.dart';

/// Grid delegate that shows [wideColumns] columns sized so exactly
/// [wideVisibleRows] full rows fit the available height — extra items
/// scroll — on wide/tablet layouts (width >= [breakpoint]). Falls back to
/// [narrowColumns] columns at a fixed [narrowAspectRatio] on phones, where
/// a dynamic row height isn't the point (the whole page scrolls anyway).
SliverGridDelegateWithFixedCrossAxisCount responsiveGridDelegate({
  required BoxConstraints constraints,
  required EdgeInsets padding,
  double spacing = 8,
  int narrowColumns = 3,
  double narrowAspectRatio = 0.85,
  int wideColumns = 4,
  int wideVisibleRows = 3,
  double breakpoint = 680,
}) {
  if (constraints.maxWidth < breakpoint) {
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: narrowColumns,
      childAspectRatio: narrowAspectRatio,
      crossAxisSpacing: spacing,
      mainAxisSpacing: spacing,
    );
  }

  final availableWidth = constraints.maxWidth - padding.horizontal;
  final availableHeight = constraints.maxHeight - padding.vertical;
  final colWidth = (availableWidth - spacing * (wideColumns - 1)) / wideColumns;
  final rowHeight =
      (availableHeight - spacing * (wideVisibleRows - 1)) / wideVisibleRows;
  final aspectRatio = (colWidth / rowHeight).clamp(0.3, 3.0);

  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: wideColumns,
    childAspectRatio: aspectRatio,
    crossAxisSpacing: spacing,
    mainAxisSpacing: spacing,
  );
}
