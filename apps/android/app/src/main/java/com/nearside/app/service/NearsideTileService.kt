package com.nearside.app.service

import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import com.nearside.app.R

@RequiresApi(Build.VERSION_CODES.N)
class NearsideTileService : TileService() {

    companion object {
        fun requestTileUpdate(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    requestListeningState(
                        context,
                        ComponentName(context, NearsideTileService::class.java)
                    )
                } catch (ignored: Exception) {}
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        val currentlyReceiving = NearsideReceiverService.isReceiving
        if (currentlyReceiving) {
            NearsideReceiverService.pause(this)
        } else {
            NearsideReceiverService.resume(this)
        }
        updateTileState(!currentlyReceiving)
    }

    private fun updateTileState(overrideReceiving: Boolean? = null) {
        val tile = qsTile ?: return
        val receiving = overrideReceiving ?: NearsideReceiverService.isReceiving

        tile.state = if (receiving) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.qs_tile_label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (receiving) "Receiving Ready" else "Dormant (Off)"
        }
        tile.icon = Icon.createWithResource(this, R.drawable.ic_nearside)
        tile.updateTile()
    }
}
