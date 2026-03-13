import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Healthcare Color Palette
  static const Color primaryMain = Color(0xFF0277BD);
  static const Color primaryLight = Color(0xFF58A5F0);
  static const Color primaryDark = Color(0xFF004C8C);

  static const Color secondaryMain = Color(0xFF37474F);
  static const Color secondaryLight = Color(0xFF62727B);
  static const Color secondaryDark = Color(0xFF102027);

  static const Color successMain = Color(0xFF2E7D32);
  static const Color successLight = Color(0xFF60AD5E);
  static const Color successDark = Color(0xFF005005);

  static const Color warningMain = Color(0xFFF57C00);
  static const Color warningLight = Color(0xFFFFB74D);
  static const Color warningDark = Color(0xFFE65100);

  static const Color errorMain = Color(0xFFC62828);
  static const Color errorLight = Color(0xFFFF5F52);
  static const Color errorDark = Color(0xFF8E0000);

  static const Color backgroundDefault = Color(0xFFFAFAFA);
  static const Color backgroundPaper = Color(0xFFFFFFFF);

  static const Color textPrimary = Color(0xFF263238);
  static const Color textSecondary = Color(0xFF546E7A);

  static const Color infoMain = Color(0xFF0288D1);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.light(
        primary: primaryMain,
        onPrimary: Colors.white,
        primaryContainer: primaryLight,
        secondary: secondaryMain,
        onSecondary: Colors.white,
        error: errorMain,
        onError: Colors.white,
        surface: backgroundPaper,
        onSurface: textPrimary,
      ),
      scaffoldBackgroundColor: backgroundDefault,
      textTheme: GoogleFonts.interTextTheme().copyWith(
        headlineLarge: GoogleFonts.inter(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        headlineMedium: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        headlineSmall: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        bodyLarge: GoogleFonts.inter(
          fontSize: 15,
          color: textSecondary,
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 14,
          color: textSecondary,
        ),
        bodySmall: GoogleFonts.inter(
          fontSize: 12,
          color: textSecondary,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryMain,
          foregroundColor: Colors.white,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          minimumSize: const Size(double.infinity, 48),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryMain,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryMain, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: primaryMain,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      dividerTheme: DividerThemeData(
        color: Colors.grey.shade200,
        thickness: 1,
      ),
    );
  }

  // Helper to get risk colour
  static Color getRiskColor(String level) {
    switch (level) {
      case 'normal':
        return successMain;
      case 'monitor':
        return warningMain;
      case 'urgent':
        return errorMain;
      default:
        return successMain;
    }
  }
}
