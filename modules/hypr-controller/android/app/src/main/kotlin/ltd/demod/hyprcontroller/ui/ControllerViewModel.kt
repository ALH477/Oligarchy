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
import ltd.demod.hyprcontroller.control.ConnState
import ltd.demod.hyprcontroller.control.HyprController
import ltd.demod.hyprcontroller.control.HyprEvent
import ltd.demod.hyprcontroller.control.parseIdLabelLines
import ltd.demod.hyprcontroller.net.TransportManager

class ControllerViewModel(app: Application) : AndroidViewModel(app) {
    private val controller = HyprController()
    private val transport = TransportManager(app, controller)

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

    fun reconnect() {
        viewModelScope.launch { transport.discover() }
    }

    fun connectManually(host: String) {
        viewModelScope.launch { transport.connectTo(host) }
    }

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

    private fun report(result: Result<String>) {
        result.onFailure { _statusMessage.value = it.message }
    }

    override fun onCleared() {
        controller.stop()
    }
}
