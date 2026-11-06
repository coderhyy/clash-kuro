# Independent review and implementation checks

Independent agent windows_login did not implement this native change. Three concrete blockers identified and fixed: unexpected exit after ready could count as normal/EOF; result write failure did not prevent success; full receipt write followed by sync failure could leave an EOF-unlocking final name. Final read-only review approved the minimal corrections: typed owner-stop/owner-eof and ACK proof; controlled termination; result persistence gate; exclusive temporary success publication via RENAME_EXCL. Existing unknown objects are preserved.

Strict experiment compilation, production helper compile-only and 153 pure fixture assertions passed; see native-verification.log. Fixed Core -t differential evidence in result.json separately proves escaped slash incompatibility. No claim of real normal/EOF is made by fixtures. Production activation, run-after-stop uninstall, upgrade and real network recovery remain open under04/06/08.
