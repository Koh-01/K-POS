/// Compares text in the order people expect: A2 comes before A10.
int naturalCompare(String left, String right) {
  final tokenPattern = RegExp(r'\d+|\D+');
  final leftTokens = tokenPattern
      .allMatches(left.trim().toLowerCase())
      .map((match) => match.group(0)!)
      .toList();
  final rightTokens = tokenPattern
      .allMatches(right.trim().toLowerCase())
      .map((match) => match.group(0)!)
      .toList();

  final commonLength = leftTokens.length < rightTokens.length
      ? leftTokens.length
      : rightTokens.length;
  for (var index = 0; index < commonLength; index++) {
    final leftToken = leftTokens[index];
    final rightToken = rightTokens[index];
    final leftNumber = int.tryParse(leftToken);
    final rightNumber = int.tryParse(rightToken);

    final comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : leftToken.compareTo(rightToken);
    if (comparison != 0) return comparison;
  }
  return leftTokens.length.compareTo(rightTokens.length);
}
