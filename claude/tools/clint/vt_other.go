//go:build !windows

package main

import "os"

// enableVT reports whether stdout is a terminal, where escape codes render as colors
func enableVT() bool {
	fi, err := os.Stdout.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
