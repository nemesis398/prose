#+build windows
package prose

import "core:os"

// process_may_be_alive cannot tell on Windows and answers true, so that
// nothing is swept on a guess.
process_may_be_alive :: proc(pid: int) -> bool {
	return true
}

// sync_directory does nothing on Windows, which has no call to sync a
// directory.
sync_directory :: proc(dir: string) -> os.Error {
	return nil
}
