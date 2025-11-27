package com.screenreflect.ui.theme

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val DarkColorScheme = darkColorScheme(
    primary = androidx.compose.ui.graphics.Color(0xFFFFFFFF),
    onPrimary = androidx.compose.ui.graphics.Color(0xFF000000),
    secondary = androidx.compose.ui.graphics.Color(0xFFE4E4E7), // Zinc 200
    tertiary = androidx.compose.ui.graphics.Color(0xFFA1A1AA), // Zinc 400
    background = androidx.compose.ui.graphics.Color(0xFF09090B), // Zinc 950
    surface = androidx.compose.ui.graphics.Color(0xFF09090B),
    onSurface = androidx.compose.ui.graphics.Color(0xFFFAFAFA), // Zinc 50
    surfaceVariant = androidx.compose.ui.graphics.Color(0xFF27272A), // Zinc 800
    onSurfaceVariant = androidx.compose.ui.graphics.Color(0xFFA1A1AA),
    error = androidx.compose.ui.graphics.Color(0xFFCF6679)
)

private val LightColorScheme = lightColorScheme(
    primary = androidx.compose.ui.graphics.Color(0xFF18181B), // Zinc 900
    onPrimary = androidx.compose.ui.graphics.Color(0xFFFFFFFF),
    secondary = androidx.compose.ui.graphics.Color(0xFF52525B), // Zinc 600
    tertiary = androidx.compose.ui.graphics.Color(0xFF71717A), // Zinc 500
    background = androidx.compose.ui.graphics.Color(0xFFFFFFFF),
    surface = androidx.compose.ui.graphics.Color(0xFFFFFFFF),
    onSurface = androidx.compose.ui.graphics.Color(0xFF09090B),
    surfaceVariant = androidx.compose.ui.graphics.Color(0xFFF4F4F5), // Zinc 100
    onSurfaceVariant = androidx.compose.ui.graphics.Color(0xFF71717A),
    error = androidx.compose.ui.graphics.Color(0xFFB00020)
)

@Composable
fun ScreenReflectTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Dynamic color is available on Android 12+
    dynamicColor: Boolean = false, // Disabled for consistent branding
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }

        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.background.toArgb() // Match background
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
