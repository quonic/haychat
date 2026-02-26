package client

import "core:fmt"
import "core:strings"
import "vendor:raylib"
import "widgets"

// Layout constants
panelSpacing: f32 = 5
serverPanelWidth: f32 = 75 - panelSpacing * 2
statusPanelHeight: f32 = 40
panelRoundness: f32 = 0.3
fontSize: f32 = 20
fontSpacing: f32 = 2


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
		size           = {serverPanelWidth, serverPanelHeight},
		anchor         = .Left,
		sideMode       = .Stretch,
		childrenLayout = .Vertical,
		shape          = .RoundedRectangle,
		roundness      = panelRoundness,
		color          = raylib.DARKGRAY,
		textColor      = raylib.WHITE,
		font           = widgets.WidgetDefaultFont,
		fontSize       = fontSize,
		fontSpacing    = fontSpacing,
		childSpacing   = 2,
	}

	// Create Friends button for server panel
	friendsButton := widgets.Image {
		id = FRIENDS_BUTTON_ID,
		parent = SERVER_PANEL_ID,
		texture = raylib.LoadTexture("../assets/icon.png"),
		position = {panelSpacing, panelSpacing},
		size = {0, 60},
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
		size = {30, 30},
		shape = .RoundedRectangle,
		roundness = panelRoundness,
		color = raylib.GREEN,
		textColor = raylib.WHITE,
		font = widgets.WidgetDefaultFont,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
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
		size           = {statusPanelWidth, statusPanelHeight},
		anchor         = .BottomLeft,
		sideMode       = .Fixed,
		childrenLayout = .Horizontal,
		shape          = .RoundedRectangle,
		roundness      = panelRoundness,
		color          = raylib.DARKGRAY,
		textColor      = raylib.WHITE,
		font           = widgets.WidgetDefaultFont,
		fontSize       = fontSize,
		fontSpacing    = fontSpacing,
		childSpacing   = 5,
	}

	// Create user display label for status panel
	userLabel := widgets.Label {
		id          = 20,
		parent      = STATUS_PANEL_ID,
		text        = config.display_name,
		size        = {120, 0},
		shape       = .Rectangle,
		color       = raylib.GRAY,
		textColor   = raylib.WHITE,
		font        = widgets.WidgetDefaultFont,
		fontSize    = fontSize,
		fontSpacing = fontSpacing,
		enabled     = true,
	}

	// Create settings button for status panel
	settingsButton := widgets.Button {
		id = 21,
		parent = STATUS_PANEL_ID,
		text = "...",
		size = {30, 30},
		shape = .Circle,
		color = raylib.GREEN,
		textColor = raylib.WHITE,
		font = widgets.WidgetDefaultFont,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
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

	statusSpacer := widgets.FlexSpacer {
		id     = 22,
		parent = STATUS_PANEL_ID,
		size   = {0, 0},
	}

	// Add panels to widget system
	widgets.add(serverPanel)

	widgets.add(statusPanel)

	widgets.addChild(SERVER_PANEL_ID, &friendsButton)

	// Add server buttons to server panel
	for server, i in config.servers {
		shortName := getShortServerName(server.name)
		serverButton := widgets.Button {
			id          = SERVER_BUTTON_BASE_ID + u32(i),
			parent      = SERVER_PANEL_ID,
			text        = shortName,
			size        = {50, 60},
			shape       = .RoundedRectangle,
			roundness   = panelRoundness,
			color       = raylib.GRAY,
			textColor   = raylib.WHITE,
			font        = widgets.WidgetDefaultFont,
			fontSize    = fontSize,
			fontSpacing = fontSpacing,
			enabled     = true,
			// TODO: Add onClick callback for server buttons
		}
		widgets.addChild(SERVER_PANEL_ID, &serverButton)
	}

	widgets.addChild(SERVER_PANEL_ID, &addServerButton)

	widgets.addChild(STATUS_PANEL_ID, &userLabel)
	widgets.addChild(STATUS_PANEL_ID, &statusSpacer)
	widgets.addChild(STATUS_PANEL_ID, &settingsButton)

}

updateUI :: proc() {
	// Update all widgets
	widgets.update()
}

drawUI :: proc() {
	// Draw all widgets
	widgets.draw()
}
