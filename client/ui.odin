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
	serverPanel := widgets.Widget {
		type = .Panel,
		rectangle = raylib.Rectangle {
			x = panelSpacing,
			y = panelSpacing,
			width = serverPanelWidth,
			height = serverPanelHeight,
		},
		anchor = .TopLeft,
		padding = 5,
		sideMode = .Stretch,
		childrenLayout = .Vertical,
		shape = .RoundedRectangle,
		roundness = panelRoundness,
		backgroundColor = raylib.DARKGRAY,
		textColor = raylib.WHITE,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
		childSpacing = 2,
		visible = true,
	}
	serverPanelHandle, _ := widgets.addWidget(serverPanel)

	// Create Friends button for server panel
	friendsButton := widgets.Widget {
		type = .Button,
		imagePath = "../assets/friends_icon.png",
		rectangle = raylib.Rectangle {
			x = 0,
			y = 0,
			width = serverPanelWidth - panelSpacing * 2,
			height = 50,
		},
		enabled = true,
		onClick = proc(widget: widgets.Handle, event: widgets.Event) {
			showFriendsList = !showFriendsList
			if showAddServer {
				showAddServer = false
			}
			if showSettings {
				showSettings = false
			}
		},
		parent = serverPanelHandle,
		visible = true,
	}

	// Create status panel widget
	statusPanelWidth: f32 = 200

	statusPanel := widgets.Widget {
		type = .Panel,
		rectangle = raylib.Rectangle {
			x = panelSpacing,
			y = panelSpacing,
			width = statusPanelWidth,
			height = statusPanelHeight,
		},
		anchor = .BottomLeft,
		padding = 5,
		sideMode = .Fixed,
		childrenLayout = .Horizontal,
		shape = .RoundedRectangle,
		roundness = panelRoundness,
		backgroundColor = raylib.DARKGRAY,
		textColor = raylib.WHITE,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
		childSpacing = 5,
		visible = true,
	}

	statusPanelHandle, _ := widgets.addWidget(statusPanel)

	// Add button to add servers
	addServerButton := widgets.Widget {
		type = .Button,
		text = "+",
		rectangle = raylib.Rectangle{x = 0, y = 0, width = 30, height = 30},
		shape = .RoundedRectangle,
		roundness = panelRoundness,
		backgroundColor = raylib.GREEN,
		textColor = raylib.WHITE,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
		enabled = true,
		onClick = proc(widget: widgets.Handle, event: widgets.Event) {
			showAddServer = !showAddServer
			if showFriendsList {
				showFriendsList = false
			}
			if showSettings {
				showSettings = false
			}
		},
		parent = serverPanelHandle,
		visible = true,
	}
	addServerButtonHandle, _ := widgets.addWidget(addServerButton)

	// Create user display label for status panel
	userLabel := widgets.Widget {
		type = .Text,
		rectangle = raylib.Rectangle{x = 0, y = 0, width = 120, height = 0},
		shape = .Rectangle,
		text = strings.clone_to_cstring(config.display_name),
		backgroundColor = raylib.GRAY,
		textColor = raylib.WHITE,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
		enabled = true,
		parent = statusPanelHandle,
		visible = true,
	}
	userLabelHandle, _ := widgets.addWidget(userLabel)

	// Create settings button for status panel
	settingsButton := widgets.Widget {
		type = .Button,
		rectangle = raylib.Rectangle{x = 0, y = 0, width = 30, height = 30},
		shape = .Circle,
		backgroundColor = raylib.GREEN,
		textColor = raylib.WHITE,
		fontSize = fontSize,
		fontSpacing = fontSpacing,
		enabled = true,
		onClick = proc(widget: widgets.Handle, event: widgets.Event) {
			showSettings = !showSettings
			if showFriendsList {
				showFriendsList = false
			}
			if showAddServer {
				showAddServer = false
			}
		},
		parent = statusPanelHandle,
		visible = true,
	}
	settingsButtonHandle, _ := widgets.addWidget(settingsButton)

	statusSpacer := widgets.Widget {
		type    = .FlexSpacer,
		parent  = statusPanelHandle,
		visible = true,
	}
	statusSpacerHandle, _ := widgets.addWidget(statusSpacer)

	friendsButton.parent = serverPanelHandle

	friendsButtonHandle, _ := widgets.addWidget(friendsButton)

	// Add server buttons to server panel
	for &server, i in config.servers {
		shortName := getShortServerName(server.name)
		serverButton := widgets.Widget {
			type = .Button,
			rectangle = raylib.Rectangle{x = 0, y = 0, width = 50, height = 60},
			shape = .RoundedRectangle,
			roundness = panelRoundness,
			backgroundColor = raylib.GRAY,
			textColor = raylib.WHITE,
			fontSize = fontSize,
			fontSpacing = fontSpacing,
			enabled = true,
			parent = serverPanelHandle,
			visible = true,
			text = strings.clone_to_cstring(shortName),
			// TODO: Add onClick callback for server buttons
		}
		server.handle, _ = widgets.addWidget(serverButton)
	}

}

updateUI :: proc() {
	// Update all widgets
	widgets.update()
}

drawUI :: proc() {
	// Draw all widgets
	widgets.draw()
}
