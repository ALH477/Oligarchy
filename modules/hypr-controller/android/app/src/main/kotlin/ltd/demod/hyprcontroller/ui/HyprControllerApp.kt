// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import ltd.demod.hyprcontroller.ui.keyboard.KeyboardScreen
import ltd.demod.hyprcontroller.ui.macro.MacroScreen
import ltd.demod.hyprcontroller.ui.panic.PanicOverlay
import ltd.demod.hyprcontroller.ui.theme.CrtBackground
import ltd.demod.hyprcontroller.ui.theme.DeModColors

@Composable
fun HyprControllerApp(vm: ControllerViewModel) {
    val navController = rememberNavController()
    val panicVisible by vm.panicVisible.collectAsState()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    CrtBackground {
        Scaffold(
            containerColor = Color.Transparent,
            bottomBar = { AppBottomNav(navController, currentRoute) },
            floatingActionButton = { PanicFab(onClick = { vm.showPanic() }) },
        ) { padding ->
            NavHost(
                navController = navController,
                startDestination = "controller",
                modifier = Modifier.padding(padding),
            ) {
                composable("controller") { ControllerScreen(vm) }
                composable("keyboard") { KeyboardScreen(vm) }
                composable("macros") { MacroScreen(vm) }
            }
        }
    }

    if (panicVisible) {
        PanicOverlay(vm)
    }
}

@Composable
private fun AppBottomNav(navController: androidx.navigation.NavController, currentRoute: String?) {
    NavigationBar(
        containerColor = Color(0xFF0A0A0F),
        contentColor = DeModColors.Turquoise,
    ) {
        NavigationBarItem(
            selected = currentRoute == "controller",
            onClick = { navController.navigate("controller") { popUpTo("controller") { inclusive = true } } },
            label = { Text("CTRL", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
            icon = { Text("⌂", fontFamily = FontFamily.Monospace, fontSize = 16.sp) },
            colors = NavigationBarItemDefaults.colors(
                selectedIconColor = DeModColors.Turquoise,
                selectedTextColor = DeModColors.Turquoise,
                unselectedIconColor = DeModColors.White.copy(alpha = 0.4f),
                unselectedTextColor = DeModColors.White.copy(alpha = 0.4f),
                indicatorColor = DeModColors.Turquoise.copy(alpha = 0.15f),
            ),
        )
        NavigationBarItem(
            selected = currentRoute == "keyboard",
            onClick = { navController.navigate("keyboard") { popUpTo("controller") } },
            label = { Text("KEYS", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
            icon = { Text("⌨", fontFamily = FontFamily.Monospace, fontSize = 16.sp) },
            colors = NavigationBarItemDefaults.colors(
                selectedIconColor = DeModColors.Turquoise,
                selectedTextColor = DeModColors.Turquoise,
                unselectedIconColor = DeModColors.White.copy(alpha = 0.4f),
                unselectedTextColor = DeModColors.White.copy(alpha = 0.4f),
                indicatorColor = DeModColors.Turquoise.copy(alpha = 0.15f),
            ),
        )
        NavigationBarItem(
            selected = currentRoute == "macros",
            onClick = { navController.navigate("macros") { popUpTo("controller") } },
            label = { Text("MACROS", fontFamily = FontFamily.Monospace, fontSize = 10.sp) },
            icon = { Text("☰", fontFamily = FontFamily.Monospace, fontSize = 16.sp) },
            colors = NavigationBarItemDefaults.colors(
                selectedIconColor = DeModColors.Turquoise,
                selectedTextColor = DeModColors.Turquoise,
                unselectedIconColor = DeModColors.White.copy(alpha = 0.4f),
                unselectedTextColor = DeModColors.White.copy(alpha = 0.4f),
                indicatorColor = DeModColors.Turquoise.copy(alpha = 0.15f),
            ),
        )
    }
}

@Composable
private fun PanicFab(onClick: () -> Unit) {
    FloatingActionButton(
        onClick = onClick,
        containerColor = DeModColors.Red,
        contentColor = DeModColors.DeepBlack,
    ) {
        Text(
            "!",
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            fontSize = 22.sp,
        )
    }
}