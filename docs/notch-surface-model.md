# Notch Surface Model

The island now separates layout from content surface:

- `closed`: collapsed notch only
- `opened + sessionList`: manual browsing of attached sessions
- `opened + approvalCard`: auto-expanded approval interaction
- `opened + questionCard`: auto-expanded question interaction

Routing rules:

- manual click or hover opens `sessionList`
- `permissionRequested` opens `approvalCard`
- `questionAsked` opens `questionCard`

Auto-expanded cards are temporary surfaces:

- they auto-collapse after a short timeout
- they also collapse when the pointer leaves the card after first hover
- they are not rendered as inline actions inside the session list

This keeps the session list focused on navigation while question and approval
flows use dedicated notification surfaces.
