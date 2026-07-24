# UserPromptSubmit hook. Injects a one-line filler-word reminder into context each
# turn. Hooks never see Claude's replies, so this cannot flag usage after the fact.
# It keeps the ban in recent context, where the drift actually happens. Best-effort:
# stdout becomes additional context, and it never blocks the turn.
Write-Output "reminder: cut filler words (honest, worth noting, genuinely, footgun, reflexive status sign-offs). every word must add info."
exit 0
