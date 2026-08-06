// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import ltd.demod.hyprcontroller.control.ConnState
import ltd.demod.hyprcontroller.control.HyprController
import ltd.demod.hyprcontroller.control.HyprEvent
import ltd.demod.hyprcontroller.control.Macro
import ltd.demod.hyprcontroller.control.MacroStep
import ltd.demod.hyprcontroller.control.MacroStore
import ltd.demod.hyprcontroller.control.parseIdLabelLines
import ltd.demod.hyprcontroller.net.TransportManager

class ControllerViewModel(app: Application) : AndroidViewModel(app) {
    internal val controller = HyprController()
    private val transport = TransportManager(app, controller)
    private val macroMutex = Mutex()

    val connection: StateFlow<ConnState> = controller.connection
    val telemetry: SharedFlow<HyprEvent> = controller.telemetry

    private val _activeWorkspace = MutableStateFlow<String?>(null)
    val activeWorkspace: StateFlow<String?> = _activeWorkspace

    private val _activeWindow = MutableStateFlow<String?>(null)
    val activeWindow: StateFlow<String?> = _activeWindow

    private val _categories = MutableStateFlow<List<Pair<String, String>>>(emptyList())
    val categories: StateFlow<List<Pair<String, String>>> = _categories

    private val _items = MutableStateFlow<List<Pair<String, String>>>(emptyList())
    val items: StateFlow<List<Pair<String, String>>> = _items

    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage

    // ── keyboard state ──────────────────────────────────────────────────────────
    private val _keyboardForwarding = MutableStateFlow(false)
    val keyboardForwarding: StateFlow<Boolean> = _keyboardForwarding

    // ── macro state ─────────────────────────────────────────────────────────────
    private val _macros = MutableStateFlow<List<Macro>>(emptyList())
    val macros: StateFlow<List<Macro>> = _macros

    private val _macroRunning = MutableStateFlow(false)
    val macroRunning: StateFlow<Boolean> = _macroRunning

    private val _macroProgress = MutableStateFlow<String?>(null)
    val macroProgress: StateFlow<String?> = _macroProgress

    // ── panic state ─────────────────────────────────────────────────────────────
    private val _panicVisible = MutableStateFlow(false)
    val panicVisible: StateFlow<Boolean> = _panicVisible

    init {
        controller.start(viewModelScope)
        viewModelScope.launch {
            controller.telemetry.collect { ev ->
                when (ev.name) {
                    "workspace" -> _activeWorkspace.value = ev.data
                    "activewindow" -> _activeWindow.value = ev.data
                }
            }
        }
        reconnect()
    }

    // ── connection ──────────────────────────────────────────────────────────────

    fun reconnect() {
        viewModelScope.launch { transport.discover() }
    }

    fun connectManually(host: String) {
        viewModelScope.launch { transport.connectTo(host) }
    }

    // ── workspace / window / media ──────────────────────────────────────────────

    fun workspace(n: Int) = viewModelScope.launch { report(controller.workspace(n)) }
    fun moveToWorkspace(n: Int) = viewModelScope.launch { report(controller.moveToWorkspace(n)) }
    fun moveFocus(dir: Char) = controller.moveFocus(dir)
    fun toggleFloating() = viewModelScope.launch { report(controller.toggleFloating()) }
    fun toggleFullscreen() = viewModelScope.launch { report(controller.toggleFullscreen()) }
    fun killActive() = viewModelScope.launch { report(controller.killActive()) }
    fun toggleScratchpad(name: String) = viewModelScope.launch { report(controller.toggleSpecialWorkspace(name)) }

    fun mediaPlayPause() = viewModelScope.launch { report(controller.mediaPlayPause()) }
    fun mediaNext() = viewModelScope.launch { report(controller.mediaNext()) }
    fun mediaPrevious() = viewModelScope.launch { report(controller.mediaPrevious()) }
    fun volumeUp() = viewModelScope.launch { report(controller.volumeUp()) }
    fun volumeDown() = viewModelScope.launch { report(controller.volumeDown()) }
    fun volumeMuteToggle() = viewModelScope.launch { report(controller.volumeMuteToggle()) }
    fun lockScreen() = viewModelScope.launch { report(controller.lockScreen()) }
    fun screenshot() = viewModelScope.launch { report(controller.screenshot()) }

    fun runExec(cmd: String) = viewModelScope.launch {
        if (cmd.isBlank()) return@launch
        controller.execRaw(cmd)
            .onSuccess { _statusMessage.value = it.ifBlank { "ran: $cmd" } }
            .onFailure { _statusMessage.value = "error: ${it.message}" }
    }

    // ── control center ──────────────────────────────────────────────────────────

    fun loadCategories() = viewModelScope.launch {
        controller.ctlCats()
            .onSuccess { _categories.value = parseIdLabelLines(it) }
            .onFailure { _statusMessage.value = "cats: ${it.message}" }
    }

    fun loadItems(category: String) = viewModelScope.launch {
        controller.ctlItems(category)
            .onSuccess { _items.value = parseIdLabelLines(it) }
            .onFailure { _statusMessage.value = "items: ${it.message}" }
    }

    fun runAction(actionId: String) = viewModelScope.launch {
        controller.ctlRun(actionId)
            .onSuccess { _statusMessage.value = it.ifBlank { "done: $actionId" } }
            .onFailure { _statusMessage.value = "error: ${it.message}" }
    }

    // ── keyboard ────────────────────────────────────────────────────────────────

    fun setKeyboardForwarding(enabled: Boolean) { _keyboardForwarding.value = enabled }

    fun sendKeyState(mod: Int, key: String, state: Int) = viewModelScope.launch {
        report(controller.sendKeyState(mod, key, state))
    }

    fun sendKeyTap(mod: Int, key: String) = viewModelScope.launch {
        controller.sendKeyTap(mod, key)
    }

    fun sendShortcut(mod: Int, key: String) = viewModelScope.launch {
        report(controller.sendShortcut(mod, key))
    }

    fun typeText(text: String) = viewModelScope.launch {
        controller.typeText(text)
            .onSuccess { _statusMessage.value = "sent ${text.length} chars" }
            .onFailure { _statusMessage.value = "type error: ${it.message}" }
    }

    // ── macros ───────────────────────────────────────────────────────────────────

    fun loadMacros() {
        _macros.value = MacroStore.load(getApplication())
    }

    fun saveMacros(macros: List<Macro>) {
        MacroStore.save(getApplication(), macros)
        _macros.value = macros
    }

    fun addMacro(macro: Macro) = saveMacros(_macros.value + macro)

    fun deleteMacro(id: String) = saveMacros(_macros.value.filter { it.id != id })

    fun updateMacro(macro: Macro) = saveMacros(_macros.value.map { if (it.id == macro.id) macro else it })

    fun runMacro(macro: Macro) {
        viewModelScope.launch {
            if (!macroMutex.tryLock()) {
                _statusMessage.value = "macro already running"
                return@launch
            }
            try {
                _macroRunning.value = true
                for ((index, step) in macro.steps.withIndex()) {
                    _macroProgress.value = "${index + 1}/${macro.steps.size}"
                    when (step) {
                        is MacroStep.HyprDispatch -> report(controller.sendReliable("hypr", step.dispatcher))
                        is MacroStep.SendShortcut -> report(controller.sendShortcut(step.mod, step.key))
                        is MacroStep.SendKeyState -> report(controller.sendKeyState(step.mod, step.key, step.state))
                        is MacroStep.CtlRun -> report(controller.ctlRun(step.actionId))
                        is MacroStep.Exec -> {
                            controller.execRaw(step.command)
                                .onSuccess { _statusMessage.value = it.ifBlank { "ran: ${step.command}" } }
                                .onFailure { _statusMessage.value = "error: ${it.message}" }
                        }
                        is MacroStep.Delay -> kotlinx.coroutines.delay(step.ms)
                    }
                }
                _macroProgress.value = null
            } finally {
                _macroRunning.value = false
                macroMutex.unlock()
            }
        }
    }

    // ── panic ────────────────────────────────────────────────────────────────────

    fun showPanic() { _panicVisible.value = true }
    fun dismissPanic() { _panicVisible.value = false }

    // ── internal ─────────────────────────────────────────────────────────────────

    private fun report(result: Result<String>) {
        result.onFailure { _statusMessage.value = it.message }
    }

    override fun onCleared() {
        controller.stop()
    }
}