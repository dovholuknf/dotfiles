# UserPromptSubmit hook. Injects a one-line filler-word reminder into context each
# turn. Hooks never see Claude's replies, so this cannot flag usage after the fact.
# It keeps the ban in recent context, where the drift actually happens. Best-effort:
# stdout becomes additional context, and it never blocks the turn.
Write-Output "reminder: every word must be load-bearing. cut hedges, throat-clearing, and editorializing adjectives (honest, genuinely, worth noting, surely, 'real'/'clean'/'robust', reflexive status sign-offs). if removing a word loses no meaning, remove it."
exit 0
