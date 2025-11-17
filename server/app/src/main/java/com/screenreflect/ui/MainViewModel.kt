package com.screenreflect.ui

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * ViewModel for main screen
 * Manages the streaming state
 */
class MainViewModel : ViewModel() {

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    fun updateStreamingState(isStreaming: Boolean) {
        _uiState.value = _uiState.value.copy(
            isStreaming = isStreaming,
            statusText = if (isStreaming) "Streaming active" else "Ready to stream"
        )
    }

    fun updateStatus(status: String) {
        _uiState.value = _uiState.value.copy(statusText = status)
    }

    fun updateConnectionInfo(port: Int) {
        _uiState.value = _uiState.value.copy(
            serverPort = port,
            statusText = "Streaming on port $port"
        )
    }

    data class UiState(
        val isStreaming: Boolean = false,
        val statusText: String = "Ready to stream",
        val serverPort: Int = 0
    )
}
