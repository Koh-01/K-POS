import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // KTS Brand
  static const Color charcoal = Color(0xFF2B2B2B);
  static const Color charcoalMid = Color(0xFF4A4A4A);
  static const Color gold = Color(0xFFC9953A);
  static const Color goldLight = Color(0xFFE8C47A);

  // Cream Palette
  static const Color cream = Color(0xFFF5F1EC);
  static const Color creamDeep = Color(0xFFEDE6DC);
  static const Color white = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE5DED5);
  static const Color borderLight = Color(0xFFF0EBE3);

  // Semantics
  static const Color success = Color(0xFF3D9E6E);
  static const Color danger = Color(0xFFD94F4F);
  static const Color info = Color(0xFF4A90D9);
  static const Color warning = Color(0xFFC9953A);
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF7A7A7A);
  static const Color textHint = Color(0xFFB0A898);

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: cream,
        colorScheme: const ColorScheme.light(
          primary: charcoal,
          onPrimary: white,
          secondary: gold,
          onSecondary: white,
          surface: white,
          onSurface: textPrimary,
          error: danger,
          onError: white,
          outline: border,
          outlineVariant: borderLight,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: charcoal,
          foregroundColor: white,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          iconTheme: IconThemeData(color: white),
          actionsIconTheme: IconThemeData(color: white),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: charcoal,
            foregroundColor: white,
            disabledBackgroundColor: Color(0xFFCCC8C2),
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: charcoal,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            side: const BorderSide(color: border),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: charcoalMid,
            textStyle: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: charcoal, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: danger),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: danger, width: 1.5),
          ),
          filled: true,
          fillColor: white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          labelStyle:
              const TextStyle(color: textSecondary, fontSize: 14),
          hintStyle: const TextStyle(color: textHint, fontSize: 14),
          prefixIconColor: textSecondary,
          suffixIconColor: textSecondary,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: border),
          ),
          margin: EdgeInsets.zero,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: creamDeep,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          side: const BorderSide(color: border),
        ),
        dividerTheme: const DividerThemeData(
          color: border,
          thickness: 1,
          space: 1,
        ),
        listTileTheme: const ListTileThemeData(
          contentPadding:
              EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? charcoal : white),
          trackColor: WidgetStateProperty.resolveWith((s) => s
                  .contains(WidgetState.selected)
              ? charcoal.withValues(alpha: 0.38)
              : border),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: white,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: border),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: charcoal,
          contentTextStyle: const TextStyle(color: white),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: charcoal,
          foregroundColor: white,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: textPrimary),
          displayMedium: TextStyle(color: textPrimary),
          displaySmall: TextStyle(color: textPrimary),
          headlineLarge:
              TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
          headlineMedium:
              TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
          headlineSmall:
              TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
          titleLarge: TextStyle(
              color: textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 18),
          titleMedium: TextStyle(
              color: textPrimary,
              fontWeight: FontWeight.w500,
              fontSize: 16),
          titleSmall: TextStyle(
              color: textPrimary,
              fontWeight: FontWeight.w500,
              fontSize: 14),
          bodyLarge: TextStyle(color: textPrimary, fontSize: 15),
          bodyMedium: TextStyle(color: textSecondary, fontSize: 14),
          bodySmall: TextStyle(color: textHint, fontSize: 12),
          labelLarge:
              TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        colorScheme: const ColorScheme.dark(
          primary: gold,
          onPrimary: white,
          secondary: goldLight,
          onSecondary: Color(0xFF1A1A1A),
          surface: Color(0xFF2B2B2B),
          onSurface: white,
          error: danger,
          onError: white,
          outline: Color(0xFF444444),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111111),
          foregroundColor: white,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: gold,
            foregroundColor: white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF444444)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF444444)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: gold, width: 1.5),
          ),
          filled: true,
          fillColor: const Color(0xFF2B2B2B),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFF2B2B2B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF3A3A3A)),
          ),
          margin: EdgeInsets.zero,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: gold,
          foregroundColor: white,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF3A3A3A),
          contentTextStyle: const TextStyle(color: white),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
}
