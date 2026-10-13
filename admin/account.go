package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"strings"
	"time"
)

// Helping the owners of self-hosted accounts: two-step authentication and recovery
// keys they lost, an email confirmation that never arrived, and notes on any account.

// removeSignInMethod turns off two-step authentication (action remove-totp) or removes
// the recovery key (remove-recovery-key), signs out everywhere when asked (sign_out)
// and tells the owner by email
func (a *App) removeSignInMethod(action string) handler {
	return func(w http.ResponseWriter, r *http.Request, s *session) {
		if a.fxa == nil {
			http.NotFound(w, r)
			return
		}
		ctx := r.Context()
		uid := strings.ToLower(r.PathValue("uid"))
		acc := a.account(r, uid)
		var err error
		var message string
		if action == "remove-totp" {
			err = a.fxa.RemoveTOTP(ctx, uid)
			message = "Turned off two-step authentication of " + accountLabel(acc, uid)
		} else {
			err = a.fxa.RemoveRecoveryKey(ctx, uid)
			message = "Removed the account recovery key of " + accountLabel(acc, uid)
		}
		var partial *partialError
		if err != nil && !errors.As(err, &partial) {
			a.doneTo(w, r, s, "/users/"+uid, "", err)
			return
		}
		// what else happened, and what did not (after the change: still audited)
		var done, problems []string
		if err != nil {
			problems = append(problems, err.Error())
		}
		if r.PostFormValue("sign_out") != "" {
			if e := a.fxa.SignOutAll(ctx, uid); e != nil {
				problems = append(problems, "signing out everywhere: "+e.Error())
			} else {
				done = append(done, "signed out everywhere")
			}
		}
		if sent, e := a.notifyOwner(acc, action, time.Now()); e != nil {
			problems = append(problems, "the notice to the owner: "+e.Error())
		} else {
			done = append(done, sent)
		}
		if len(done) > 0 {
			message += " (" + strings.Join(done, ", ") + ")"
		}
		err = nil
		if len(problems) > 0 {
			err = &partialError{errors.New(strings.Join(problems, "; "))}
		}
		a.doneTo(w, r, s, "/users/"+uid, message, err)
	}
}

// notifyOwner emails the owner of an account what an admin changed: what happened,
// for the message and the event
func (a *App) notifyOwner(acc *FxaAccount, action string, at time.Time) (string, error) {
	if acc == nil {
		return "", errors.New("account not found")
	}
	// one plain address: it goes into the To header
	if addr, err := mail.ParseAddress(acc.Email); err != nil || addr.Address != acc.Email || addr.Name != "" {
		return "", fmt.Errorf("not an address to write to")
	}
	if a.mailer == nil {
		return "no notice to the owner: no SMTP server (FXA_SMTP_HOST)", nil
	}
	subject, body := ownerNotice(action, acc.Email, a.contentURL, at)
	if err := a.sendMail(acc.Email, subject, body); err != nil {
		return "", err
	}
	return "owner notified", nil
}

// ownerNotice is the email to the owner of an account after an admin turned off two-step
// authentication or removed the recovery key: someone asking for it may not be them
func ownerNotice(action, email, contentURL string, at time.Time) (subject, body string) {
	when := formatTime(at, adminZone) + " (" + adminZone.String() + ")"
	settings := contentURL + "/settings"
	if action == "remove-totp" {
		subject = "Two-step authentication turned off on your account"
		body = "An administrator turned off two-step authentication on your account " + email + " on " + when +
			", with its backup authentication codes and recovery phone.\r\n\r\n" +
			"You now sign in with your password and a code sent to this address. Turn two-step authentication on again in your account settings: " + settings + "\r\n"
	} else {
		subject = "Account recovery key removed from your account"
		body = "An administrator removed the account recovery key of your account " + email + " on " + when + ".\r\n\r\n" +
			"Create a new one in your account settings, so that a password reset keeps your synced data: " + settings + "\r\n"
	}
	body += "\r\nIf you did not ask for this, change your password there and tell your administrator.\r\n"
	return subject, body
}

// confirmEmail marks the email of an unconfirmed account as confirmed
func (a *App) confirmEmail(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	uid := strings.ToLower(r.PathValue("uid"))
	acc := a.account(r, uid)
	err := a.fxa.ConfirmEmail(r.Context(), uid)
	a.doneTo(w, r, s, "/users/"+uid, "Confirmed the email of "+accountLabel(acc, uid), err)
}

// setNote saves the note of an account: with self-hosted accounts or Mozilla's, any
// account that has an account page
func (a *App) setNote(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	uid := strings.ToLower(r.PathValue("uid"))
	label, ok := a.knownAccount(r, uid)
	if !ok {
		http.NotFound(w, r)
		return
	}
	note, err := cleanNote(r.PostFormValue("note"))
	if err != nil {
		a.doneTo(w, r, s, "/users/"+uid, "", err)
		return
	}
	err = a.sync.SetNote(ctx, uid, note, noteAuthor(s))
	message := "Removed the note of " + label
	if note != "" {
		message = fmt.Sprintf("Note of %s set to %q", label, oneLine(note, 200))
	}
	a.doneTo(w, r, s, "/users/"+uid, message, err)
}

// addToNote adds text (the reason of disabling) to the note of an account
func (a *App) addToNote(ctx context.Context, uid, text string, s *session) error {
	old, err := a.sync.Note(ctx, uid)
	if err != nil {
		return err
	}
	// as in the event log (auditText), within maxNote
	text, err = cleanNote(oneLine(strings.TrimSpace(text), maxReason))
	if err != nil {
		return err
	}
	note := text
	if old != nil && old.Text != "" {
		note = old.Text + "; " + text
	}
	// the newest at the end: cut the oldest
	if runes := []rune(note); len(runes) > maxNote {
		note = string(runes[len(runes)-maxNote:])
	}
	return a.sync.SetNote(ctx, uid, note, noteAuthor(s))
}

func noteAuthor(s *session) string {
	return auditWho(s)
}

// knownAccount: the label of an account with that uid, self-hosted or using Sync
func (a *App) knownAccount(r *http.Request, uid string) (string, bool) {
	if len(uid) == 0 || len(uid) > 64 {
		return "", false
	}
	if a.fxa != nil {
		if _, err := accountID(uid); err == nil {
			if acc := a.account(r, uid); acc != nil {
				return accountLabel(acc, uid), true
			}
		}
	}
	user, err := a.sync.User(r.Context(), uid)
	if err != nil || user == nil {
		return "", false
	}
	return accountLabel(nil, uid), true
}
