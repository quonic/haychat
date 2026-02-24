package client

import "core:strings"
import "vendor:raylib"
import "widgets"

// Layout constants
panelSpacing: f32 = 5
serverPanelWidth: f32 = 75
statusPanelHeight: f32 = 40
panelRoundness: f32 = 0.3

// Widget IDs for easy reference
SERVER_PANEL_ID: u32 = 1
STATUS_PANEL_ID: u32 = 2
FRIENDS_BUTTON_ID: u32 = 10
ADD_SERVER_BUTTON_ID: u32 = 11
SERVER_BUTTON_BASE_ID: u32 = 100

// Visible UI state
showFriendsList: bool
showAddServer: bool
showSettings: bool


// Initialize the UI by creating panels and buttons based on the configuration
initUI :: proc() {

	// Initialize widgets system
	widgets.init()

	// Create server panel widget
	serverPanelHeight :=
		f32(raylib.GetScreenHeight()) - panelSpacing * 2 - statusPanelHeight - panelSpacing
	serverPanel := widgets.Panel {
		id             = SERVER_PANEL_ID,
		title          = "",
		position       = {panelSpacing, panelSpacing},
		size           = {serverPanelWidth - panelSpacing * 2, serverPanelHeight},
		anchor         = .Left,
		sideMode       = .Stretch,
		childrenLayout = .Vertical,
		shape          = .RoundedRectangle,
		roundness      = panelRoundness,
		font           = widgets.WidgetDefaultFont,
		fontSize       = 20,
		fontSpacing    = 0,
		childSpacing   = panelSpacing,
	}

	// Create Friends button for server panel
	friendsButton := widgets.Button {
		id = FRIENDS_BUTTON_ID,
		parent = SERVER_PANEL_ID,
		text = "Friends",
		position = {panelSpacing, panelSpacing},
		size = {serverPanel.size.x - panelSpacing * 2, 30},
		shape = .RoundedRectangle,
		roundness = panelRoundness,
		font = widgets.WidgetDefaultFont,
		fontSize = 16,
		fontSpacing = 0,
		enabled = true,
		onClick = proc() {
			showFriendsList = !showFriendsList
			if showAddServer {
				showAddServer = false
			}
			if showSettings {
				showSettings = false
			}
		},
	}

	// Add button to add servers
	addServerButton := widgets.Button {
		id = ADD_SERVER_BUTTON_ID,
		parent = SERVER_PANEL_ID,
		text = "+",
		position = {panelSpacing, serverPanel.size.y - 30 - panelSpacing},
		size = {serverPanel.size.x - panelSpacing * 2, 30},
		shape = .RoundedRectangle,
		roundness = panelRoundness,
		font = widgets.WidgetDefaultFont,
		fontSize = 16,
		fontSpacing = 0,
		enabled = true,
		onClick = proc() {
			showAddServer = !showAddServer
			if showFriendsList {
				showFriendsList = false
			}
			if showSettings {
				showSettings = false
			}
		},
	}

	// Create status panel widget
	statusPanelWidth: f32 = 200

	statusPanel := widgets.Panel {
		id             = STATUS_PANEL_ID,
		title          = "",
		position       = {panelSpacing, panelSpacing},
		size           = {
			statusPanelWidth - panelSpacing * 2,
			statusPanelHeight - panelSpacing * 2,
		},
		anchor         = .BottomLeft,
		sideMode       = .Fixed,
		childrenLayout = .Horizontal,
		shape          = .RoundedRectangle,
		roundness      = panelRoundness,
		font           = widgets.WidgetDefaultFont,
		fontSize       = 14,
		fontSpacing    = 0,
		childSpacing   = panelSpacing,
	}

	// Create user display label for status panel
	userLabel := widgets.Label {
		id          = 20,
		parent      = STATUS_PANEL_ID,
		text        = config.display_name,
		position    = {panelSpacing * 2 + 10, panelSpacing},
		size        = {
			statusPanel.size.x - panelSpacing * 4 - 40,
			statusPanel.size.y - panelSpacing * 2,
		},
		shape       = .Rectangle,
		font        = widgets.WidgetDefaultFont,
		fontSize    = 14,
		fontSpacing = 0,
		enabled     = true,
	}

	// Create settings button for status panel
	settingsButton := widgets.Button {
		id = 21,
		parent = STATUS_PANEL_ID,
		text = "...",
		position = {statusPanel.size.x - 30 - panelSpacing, panelSpacing},
		size = {30, 30},
		shape = .Circle,
		font = widgets.WidgetDefaultFont,
		fontSize = 12,
		fontSpacing = 0,
		enabled = true,
		onClick = proc() {
			showSettings = !showSettings
			if showFriendsList {
				showFriendsList = false
			}
			if showAddServer {
				showAddServer = false
			}
		},
	}

	// Add panels to widget system
	widgets.add(serverPanel)

	widgets.add(statusPanel)

	widgets.addChild(SERVER_PANEL_ID, widgets.Widget(friendsButton))

	// Add server buttons to server panel
	for server, i in config.servers {
		shortName := getShortServerName(server.name)
		serverButton := widgets.Button {
			id          = SERVER_BUTTON_BASE_ID + u32(i),
			parent      = SERVER_PANEL_ID,
			text        = shortName,
			position    = {
				panelSpacing,
				panelSpacing +
				30 +
				f32(i) * (serverPanel.size.x - panelSpacing * 2 + panelSpacing),
			},
			size        = {
				serverPanel.size.x - panelSpacing * 2,
				serverPanel.size.x - panelSpacing * 2,
			},
			shape       = .RoundedRectangle,
			roundness   = panelRoundness,
			font        = widgets.WidgetDefaultFont,
			fontSize    = 14,
			fontSpacing = 0,
			enabled     = true,
			// TODO: Add onClick callback for server buttons
		}
		widgets.addChild(SERVER_PANEL_ID, widgets.Widget(serverButton))
	}

	widgets.addChild(SERVER_PANEL_ID, widgets.Widget(addServerButton))
	widgets.addChild(STATUS_PANEL_ID, widgets.Widget(userLabel))
	widgets.addChild(STATUS_PANEL_ID, widgets.Widget(settingsButton))

}

updateUI :: proc() {
	// Update all widgets
	widgets.update()
}

drawUI :: proc() {
	// Draw all widgets
	widgets.draw()
}
