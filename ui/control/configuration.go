//go:build linux

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

const maxConfigurationBytes = 512 * 1024

func configurationSHA256(content []byte) string {
	digest := sha256.Sum256(content)
	return hex.EncodeToString(digest[:])
}

func validConfigurationContent(content string) bool {
	return content != "" && len(content) <= maxConfigurationBytes && utf8.ValidString(content) && !strings.ContainsRune(content, '\x00')
}

func (s *controlService) readConfiguration() (map[string]any, error) {
	content, missing, err := readRegularFile(s.config.ConfigPath, maxConfigurationBytes)
	if missing || err != nil || !validConfigurationContent(string(content)) {
		return nil, controlFailure(503, "configuration_unavailable", "The managed ocserv configuration is unavailable.")
	}
	return map[string]any{
		"content": string(content), "filename": "ocserv.conf", "bytes": len(content),
		"sha256": configurationSHA256(content),
	}, nil
}

func (s *controlService) writeConfiguration(content, previousSHA256 string) (map[string]any, error) {
	if !validConfigurationContent(content) || len(previousSHA256) != 64 {
		return nil, controlFailure(422, "invalid_configuration", "The ocserv configuration is empty, too large, or not valid UTF-8.")
	}
	if _, err := hex.DecodeString(previousSHA256); err != nil {
		return nil, controlFailure(422, "invalid_configuration", "The previous configuration revision is invalid.")
	}
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()

	original, missing, err := readRegularFile(s.config.ConfigPath, maxConfigurationBytes)
	if missing || err != nil || !validConfigurationContent(string(original)) {
		return nil, controlFailure(503, "configuration_unavailable", "The managed ocserv configuration is unavailable.")
	}
	if configurationSHA256(original) != strings.ToLower(previousSHA256) {
		return nil, controlFailure(409, "configuration_changed", "The ocserv configuration changed after it was loaded.")
	}
	info, err := os.Lstat(s.config.ConfigPath)
	if err != nil || !info.Mode().IsRegular() {
		return nil, controlFailure(503, "configuration_unavailable", "The managed ocserv configuration is unsafe.")
	}
	uid, gid := -1, -1
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		uid, gid = int(stat.Uid), int(stat.Gid)
	}
	candidate, err := writeConfigurationCandidate(s.config.ConfigPath, []byte(content), info.Mode().Perm(), uid, gid)
	if err != nil {
		return nil, controlFailure(500, "configuration_write_failed", "The ocserv configuration candidate could not be written safely.")
	}
	defer os.Remove(candidate)
	if _, err = s.runner.Run([]string{s.config.OCServBin, "--test-config", "--config=" + candidate}, ""); err != nil {
		return nil, controlFailure(422, "invalid_configuration", "ocserv rejected the configuration. Check the directives and referenced files.")
	}
	if err = os.Rename(candidate, s.config.ConfigPath); err != nil {
		return nil, controlFailure(500, "configuration_write_failed", "The ocserv configuration could not be replaced atomically.")
	}
	if err = syncDirectory(filepath.Dir(s.config.ConfigPath)); err != nil {
		if rollbackErr := restoreConfiguration(s.config.ConfigPath, original, info.Mode().Perm(), uid, gid); rollbackErr != nil {
			return nil, controlFailure(500, "rollback_failed", "The previous ocserv configuration could not be restored safely.")
		}
		return nil, controlFailure(500, "configuration_write_failed", "The ocserv configuration could not be committed safely.")
	}
	if err = createHostTriggerFile(s.config.RestartTrigger, "restart_unavailable", "The ocserv restart bridge is unavailable."); err != nil {
		if rollbackErr := restoreConfiguration(s.config.ConfigPath, original, info.Mode().Perm(), uid, gid); rollbackErr != nil {
			return nil, controlFailure(500, "rollback_failed", "The previous ocserv configuration could not be restored safely.")
		}
		return nil, err
	}
	updated := []byte(content)
	return map[string]any{
		"saved": true, "restarting": true, "bytes": len(updated), "sha256": configurationSHA256(updated),
	}, nil
}

func writeConfigurationCandidate(target string, content []byte, mode os.FileMode, uid, gid int) (string, error) {
	directory := filepath.Dir(target)
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("unsafe configuration directory")
	}
	file, err := os.CreateTemp(directory, ".ocserv.conf.candidate.*")
	if err != nil {
		return "", err
	}
	name := file.Name()
	cleanup := func() {
		_ = file.Close()
		_ = os.Remove(name)
	}
	if err = file.Chmod(mode); err != nil {
		cleanup()
		return "", err
	}
	if uid >= 0 && gid >= 0 {
		if err = file.Chown(uid, gid); err != nil && !errors.Is(err, syscall.EPERM) {
			cleanup()
			return "", err
		}
	}
	if _, err = file.Write(content); err != nil {
		cleanup()
		return "", err
	}
	if err = file.Sync(); err != nil {
		cleanup()
		return "", err
	}
	if err = file.Close(); err != nil {
		_ = os.Remove(name)
		return "", err
	}
	return name, nil
}

func restoreConfiguration(target string, content []byte, mode os.FileMode, uid, gid int) error {
	candidate, err := writeConfigurationCandidate(target, content, mode, uid, gid)
	if err != nil {
		return err
	}
	defer os.Remove(candidate)
	if err = os.Rename(candidate, target); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(target))
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
