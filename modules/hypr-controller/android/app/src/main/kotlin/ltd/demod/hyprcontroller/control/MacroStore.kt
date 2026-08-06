// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.control

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

sealed class MacroStep {
    data class HyprDispatch(val dispatcher: String) : MacroStep()
    data class SendShortcut(val mod: Int, val key: String) : MacroStep()
    data class SendKeyState(val mod: Int, val key: String, val state: Int) : MacroStep()
    data class CtlRun(val actionId: String) : MacroStep()
    data class Exec(val command: String) : MacroStep()
    data class Delay(val ms: Long) : MacroStep()

    fun toJson(): JSONObject = when (this) {
        is HyprDispatch -> JSONObject().put("type", "hypr_dispatch").put("dispatcher", dispatcher)
        is SendShortcut -> JSONObject().put("type", "send_shortcut").put("mod", mod).put("key", key)
        is SendKeyState -> JSONObject().put("type", "send_keystate").put("mod", mod).put("key", key).put("state", state)
        is CtlRun -> JSONObject().put("type", "ctl_run").put("actionId", actionId)
        is Exec -> JSONObject().put("type", "exec").put("command", command)
        is Delay -> JSONObject().put("type", "delay").put("ms", ms)
    }

    companion object {
        fun fromJson(json: JSONObject): MacroStep = when (json.getString("type")) {
            "hypr_dispatch" -> HyprDispatch(json.getString("dispatcher"))
            "send_shortcut" -> SendShortcut(json.getInt("mod"), json.getString("key"))
            "send_keystate" -> SendKeyState(json.getInt("mod"), json.getString("key"), json.getInt("state"))
            "ctl_run" -> CtlRun(json.getString("actionId"))
            "exec" -> Exec(json.getString("command"))
            "delay" -> Delay(json.getLong("ms"))
            else -> throw IllegalArgumentException("Unknown macro step type: ${json.getString("type")}")
        }
    }
}

data class Macro(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val steps: List<MacroStep>,
    val iconName: String? = null,
)

object MacroStore {
    private const val PREFS_NAME = "hypr_controller_macros"
    private const val KEY_MACROS = "macros_json"

    fun load(context: Context): List<Macro> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_MACROS, null)
        if (json != null) {
            return parseMacroList(json)
        }
        val defaults = defaultMacros()
        save(context, defaults)
        return defaults
    }

    fun save(context: Context, macros: List<Macro>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val arr = JSONArray()
        for (macro in macros) {
            val stepsArr = JSONArray()
            for (step in macro.steps) stepsArr.put(step.toJson())
            arr.put(JSONObject()
                .put("id", macro.id)
                .put("name", macro.name)
                .put("steps", stepsArr)
                .put("iconName", macro.iconName ?: JSONObject.NULL))
        }
        prefs.edit().putString(KEY_MACROS, arr.toString()).apply()
    }

    private fun parseMacroList(json: String): List<Macro> {
        val arr = JSONArray(json)
        val macros = mutableListOf<Macro>()
        for (i in 0 until arr.length()) {
            val obj = arr.getJSONObject(i)
            val stepsArr = obj.getJSONArray("steps")
            val steps = mutableListOf<MacroStep>()
            for (j in 0 until stepsArr.length()) {
                steps.add(MacroStep.fromJson(stepsArr.getJSONObject(j)))
            }
            macros.add(Macro(
                id = obj.getString("id"),
                name = obj.getString("name"),
                steps = steps,
                iconName = if (obj.isNull("iconName")) null else obj.getString("iconName"),
            ))
        }
        return macros
    }

    fun defaultMacros(): List<Macro> = listOf(
        Macro(
            id = "default-lock",
            name = "Lock Screen",
            steps = listOf(MacroStep.Exec("hyprlock")),
            iconName = "LOCK",
        ),
        Macro(
            id = "default-emergency-ws",
            name = "Emergency Workspace",
            steps = listOf(MacroStep.HyprDispatch("workspace 1")),
            iconName = "EWS",
        ),
        Macro(
            id = "default-fullscreen",
            name = "Full Screen",
            steps = listOf(MacroStep.HyprDispatch("fullscreen")),
            iconName = "FULL",
        ),
        Macro(
            id = "default-close-all",
            name = "Close All Windows",
            steps = listOf(MacroStep.Exec("bash -c 'while hyprctl dispatch killactive 2>/dev/null; do sleep 0.1; done'")),
            iconName = "KILL",
        ),
    )
}