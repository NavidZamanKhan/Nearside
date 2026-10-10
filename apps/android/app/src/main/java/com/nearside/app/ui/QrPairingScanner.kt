package com.nearside.app.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import com.nearside.app.crypto.QRPairingPayload
import com.nearside.app.diagnostics.*
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Camera exists only while this scan tab is composed and the app lifecycle is active. */
@Composable
fun QrPairingScanner(onCaptured: (String) -> Unit, onManualEntry: () -> Unit) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var requested by remember { mutableStateOf(false) }
    var captured by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; requested = true }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (captured != null) {
            Text("QR captured. Ready to verify this device.")
            Button(onClick = { onCaptured(captured!!) }) { Text("Verify and pair") }
            TextButton(onClick = { captured = null; error = null }) { Text("Scan again") }
        } else if (granted) {
            CameraQrPreview(onDecoded = { text ->
                val payload = QRPairingPayload.fromUri(text)
                if (payload == null) {
                    error = "This is not a valid Nearside pairing QR code."
                    NearsideLogger.warn("pairing", "parseQR", "Malformed QR pairing payload", state = "rejected", errorCode = NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD)
                } else if (payload.isExpired) {
                    error = "This QR code expired. Ask the other device to display a fresh code."
                    NearsideLogger.warn("pairing", "parseQR", "QR pairing session expired", state = "rejected", correlationId = payload.sessionId, errorCode = NearsideErrorCode.PAIRING_SESSION_EXPIRED)
                } else { captured = text; error = null }
            }, onFailure = { error = "Camera unavailable. Use manual URI entry or check camera permission." })
            Text("Align the other device’s Nearside QR code within the camera view.")
        } else {
            Text(if (requested) "Camera permission was denied. Allow camera access to scan, or paste the pairing URI." else "Camera access is needed only to scan a pairing QR code.")
            TextButton(onClick = { permission.launch(Manifest.permission.CAMERA) }) { Text("Allow camera") }
            TextButton(onClick = {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
            }) { Text("Open app settings") }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        TextButton(onClick = onManualEntry) { Text("Paste URI manually") }
    }
}

@Composable
private fun CameraQrPreview(onDecoded: (String) -> Unit, onFailure: () -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context).apply { implementationMode = PreviewView.ImplementationMode.COMPATIBLE } }
    val decoded by rememberUpdatedState(onDecoded)
    val failed by rememberUpdatedState(onFailure)
    DisposableEffect(lifecycle, previewView) {
        val main = ContextCompat.getMainExecutor(context)
        val executor = Executors.newSingleThreadExecutor()
        val disposed = AtomicBoolean(false)
        val delivered = AtomicBoolean(false)
        val future = ProcessCameraProvider.getInstance(context)
        val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        var provider: ProcessCameraProvider? = null
        var lastText: String? = null
        analysis.setAnalyzer(executor) { frame ->
            try {
                if (!disposed.get() && !delivered.get()) {
                    val plane = frame.planes[0]
                    val bytes = ByteArray(frame.width * frame.height)
                    val buffer = plane.buffer.duplicate()
                    val start = buffer.position()
                    for (row in 0 until frame.height) for (column in 0 until frame.width) {
                        bytes[row * frame.width + column] = buffer.get(start + row * plane.rowStride + column * plane.pixelStride)
                    }
                    val source = PlanarYUVLuminanceSource(bytes, frame.width, frame.height, 0, 0, frame.width, frame.height, false)
                    val reader = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE))) }
                    val text = try { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text } finally { reader.reset() }
                    if (text != lastText) {
                        lastText = text
                        if (QRPairingPayload.fromUri(text)?.isExpired == false) delivered.set(true)
                        main.execute { if (!disposed.get()) decoded(text) }
                    }
                }
            } catch (_: ReaderException) { /* Normal frame without a readable QR. */ }
              catch (_: Exception) { main.execute { if (!disposed.get()) failed() } }
            finally { frame.close() }
        }
        future.addListener({
            if (!disposed.get()) try {
                provider = future.get()
                provider!!.bindToLifecycle(lifecycle, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (error: Exception) {
                NearsideLogger.warn("pairing", "startScanner", "QR camera could not start", state = "unavailable", underlyingError = error)
                failed()
            }
        }, main)
        onDispose {
            disposed.set(true); analysis.clearAnalyzer()
            provider?.unbind(preview, analysis); executor.shutdown()
        }
    }
    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxWidth().height(240.dp))
}
