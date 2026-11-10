import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared visual language for every NUDGE screen.
abstract final class NudgeTheme {
  static const pagePadding = EdgeInsets.all(20);
  static const sectionGap = 24.0;
  static const radius = 18.0;

  static LinearGradient heroGradient(Brightness brightness) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: brightness == Brightness.dark
        ? const [Color(0xff51309a), Color(0xff702769)]
        : const [Color(0xffb59aef), Color(0xffded0fb)],
  );

  static const darkCanvas = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xff29205d), Color(0xff351447)],
  );

  static const darkFocus = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xff302373), Color(0xff501570), Color(0xff741955)],
  );

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = Color(dark ? 0xff241b45 : 0xfffaf9fd);
    final surface = Color(dark ? 0xff33264b : 0xffffffff);
    final text = Color(dark ? 0xfffaf7ff : 0xff252231);
    final secondary = Color(dark ? 0xffd3c8e3 : 0xff686176);
    final accent = Color(dark ? 0xffcbb6fa : 0xff6d43c6);
    final border = Color(dark ? 0xff635475 : 0xffe1dbe9);
    final colors =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: Color(dark ? 0xff251543 : 0xffffffff),
          primaryContainer: Color(dark ? 0xff4c3769 : 0xffeee5fc),
          onPrimaryContainer: text,
          secondary: accent,
          onSecondary: Color(dark ? 0xff251543 : 0xffffffff),
          surface: surface,
          onSurface: text,
          onSurfaceVariant: secondary,
          surfaceContainerLowest: background,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: surface,
          surfaceContainerHighest: Color(dark ? 0xff4c3769 : 0xffeee5fc),
          outline: secondary,
          outlineVariant: border,
          surfaceTint: Colors.transparent,
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      fontFamily: 'Roboto',
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final button = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'Roboto',
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: base.textTheme.copyWith(
        headlineMedium: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 28,
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        headlineSmall: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 24,
          height: 1.25,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        titleLarge: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 20,
          height: 1.3,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        titleMedium: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 16,
          height: 1.4,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 16,
          height: 1.5,
          color: text,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 16,
          height: 1.5,
          color: text,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 14,
          height: 1.45,
          color: secondary,
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 20,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        systemOverlayStyle:
            (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                .copyWith(statusBarColor: Colors.transparent),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: shape,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(style: button),
      textButtonTheme: TextButtonThemeData(style: button),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        height: 72,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Roboto',
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: text,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, space: 24),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}
