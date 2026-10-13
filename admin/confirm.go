package main

import (
	"net/http"
	"strings"
)

// Destructive actions are never one click away: their links lead to a page that says
// what will happen, with the form that does it (POST, with the session's token). The
// POST routes stay as they are, for scripts and the tests. Without JavaScript: the
// CSP has default-src 'none'.

type confirmAction struct {
	Title   string   // "Disable alice@example.com?" is Title + email
	Button  string   // the submit button
	Effects []string // what happens
	// for deleting: the admin types the account's email too (field confirm_email), or
	// with TypeUID its id (no email: Mozilla's accounts)
	TypeEmail, TypeUID bool
	// checkboxes, off by default
	Checks []confirmCheck
	// hidden fields of the form (a collection...)
	Hidden map[string]string
	// the devices and sessions signed out are listed
	Lists bool
	// the reason also goes into the account's note
	ReasonToNote bool
	// a checkbox "also sign out everywhere" (field sign_out), on by default: after a
	// takeover the attacker's sessions go too
	SignOut bool
}

type confirmCheck struct{ Name, Label string }

var accountActions = map[string]confirmAction{
	"disable": {
		Title:  "Disable",
		Button: "Disable the account",
		Effects: []string{
			"Every device and session below is signed out, and the account's OAuth tokens are revoked.",
			"Nobody can sign in to the account until you enable it again; its data stays.",
			"Firefox may sync for up to 1 hour more with the Sync token it has (the Sync server also remembers a checked access token for 5 minutes).",
		},
		Lists:        true,
		ReasonToNote: true,
	},
	"sign-out-all": {
		Title:  "Sign out everywhere",
		Button: "Sign out everywhere",
		Effects: []string{
			"Every device and session below is signed out, and the account's OAuth tokens are revoked: each Firefox asks to sign in again.",
			"The account stays active: its owner can sign in again right away, e.g. after changing the password.",
			"Firefox may sync for up to 1 hour more with the Sync token it has (the Sync server also remembers a checked access token for 5 minutes).",
		},
		Lists: true,
	},
	"remove-totp": {
		Title:  "Turn off two-step authentication of",
		Button: "Turn off two-step authentication",
		Effects: []string{
			"The authenticator app, the backup authentication codes and the recovery phone of the account stop working: its owner signs in with the password and a code sent by email.",
			"Make sure who is asking first: from now on the password and the mailbox are enough to get in.",
			"The owner gets an email saying that an administrator turned it off. They can turn it on again in the account settings.",
		},
		SignOut: true,
	},
	"remove-recovery-key": {
		Title:  "Remove the account recovery key of",
		Button: "Remove the recovery key",
		Effects: []string{
			"The recovery key stops working: a password reset without it loses the Sync data, unless a Firefox that still has the data uploads it again.",
			"The owner gets an email saying that an administrator removed it. They can create a new one in the account settings.",
		},
		SignOut: true,
	},
	"confirm-email": {
		Title:  "Confirm the email of",
		Button: "Confirm the email",
		Effects: []string{
			"The email is marked as confirmed without the code sent to it: this skips the proof that whoever signed up owns the address. Do it only when you know who they are.",
			"Their current sign-in stays unconfirmed: signing in again sends a new code to the address.",
		},
	},
}

// confirmPage is the data of confirm.html
func (a *App) confirmPage(w http.ResponseWriter, r *http.Request, s *session, act confirmAction, post string) (map[string]any, *FxaAccount) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return nil, nil
	}
	uid := strings.ToLower(r.PathValue("uid"))
	if _, err := accountID(uid); err != nil {
		http.NotFound(w, r)
		return nil, nil
	}
	acc, err := a.fxa.Account(r.Context(), uid)
	if err != nil {
		http.Error(w, "Accounts: "+err.Error(), http.StatusInternalServerError)
		return nil, nil
	}
	if acc == nil {
		http.NotFound(w, r)
		return nil, nil
	}
	data := a.base(s)
	data["Account"], data["Name"], data["Action"], data["Post"], data["Back"], data["MaxReason"] = acc, acc.Email, act, post, "/users/"+uid, maxReason
	devices, sessions, err := a.fxa.Devices(r.Context(), uid)
	if err != nil {
		data["Errors"] = []string{"Devices: " + err.Error()}
	}
	data["Devices"], data["Sessions"] = devices, sessions
	return data, acc
}

func (a *App) confirmAccount(w http.ResponseWriter, r *http.Request, s *session) {
	act, ok := accountActions[r.PathValue("action")]
	if !ok {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	data, _ := a.confirmPage(w, r, s, act, "/accounts/"+uid+"/"+r.PathValue("action"))
	if data == nil {
		return
	}
	a.render(w, "confirm.html", data)
}

func (a *App) confirmDevice(w http.ResponseWriter, r *http.Request, s *session) {
	act := confirmAction{Title: "Sign out a device of", Button: "Sign out the device", Lists: true,
		Effects: []string{
			"The device below is removed with the session or token it signed in with: Firefox there asks to sign in again.",
			"Its access tokens work until they expire (FXA_ACCESS_TOKEN_LIFETIME); the account keeps working everywhere else.",
		}}
	uid, id := strings.ToLower(r.PathValue("uid")), strings.ToLower(r.PathValue("id"))
	data, _ := a.confirmPage(w, r, s, act, "/users/"+uid+"/devices/"+id+"/sign-out")
	if data == nil {
		return
	}
	devices, _ := data["Devices"].([]Device)
	var only []Device
	for _, d := range devices {
		if d.ID == id {
			only = append(only, d)
		}
	}
	if len(only) == 0 && data["Errors"] == nil {
		http.NotFound(w, r)
		return
	}
	data["Devices"], data["Sessions"] = only, nil
	a.render(w, "confirm.html", data)
}

func (a *App) confirmSession(w http.ResponseWriter, r *http.Request, s *session) {
	act := confirmAction{Title: "Sign out a session of", Button: "Sign out the session", Lists: true,
		Effects: []string{
			"The session below ends, and the device it registered: the browser there asks to sign in again.",
			"The account keeps working everywhere else.",
		}}
	uid, ref := strings.ToLower(r.PathValue("uid")), strings.ToLower(r.PathValue("ref"))
	data, _ := a.confirmPage(w, r, s, act, "/users/"+uid+"/sessions/"+ref+"/sign-out")
	if data == nil {
		return
	}
	sessions, _ := data["Sessions"].([]Session)
	var only []Session
	for _, se := range sessions {
		if se.Ref == ref {
			only = append(only, se)
		}
	}
	if len(only) == 0 && data["Errors"] == nil {
		http.NotFound(w, r)
		return
	}
	data["Devices"], data["Sessions"] = nil, only
	a.render(w, "confirm.html", data)
}
