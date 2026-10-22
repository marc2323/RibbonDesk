use std::{
    env, fs,
    io::{Error, ErrorKind, Result, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

use tracing::{info, warn};

use crate::util::exe_path;

/// The bundle identifier for the `paneru` service.
pub const ID: &str = "com.github.karinushka.paneru";

/// `Service` manages the installation, uninstallation, starting, and stopping of the `paneru` application as a launchd service.
/// It encapsulates the `launchctl::Service` and the path to the executable.
#[derive(Debug)]
pub struct Service {
    /// The underlying `launchctl::Service` instance.
    pub raw: launchctl::Service,
    /// The absolute path to the `paneru` executable.
    pub bin_path: PathBuf,
    /// The user's home directory.
    home_dir: PathBuf,
}

impl Service {
    /// Creates a new `Service` instance.
    /// It determines the executable path and constructs the `launchctl::Service` with appropriate settings.
    ///
    /// # Arguments
    ///
    /// * `name` - The name of the service (e.g., "com.github.karinushka.paneru").
    ///
    /// # Returns
    ///
    /// `Ok(Self)` if the service is created successfully, otherwise `Err(Error)` if the executable path or home directory cannot be found.
    pub fn try_new(name: &str) -> Result<Self> {
        let home_dir = env::home_dir().ok_or(Error::new(
            ErrorKind::NotFound,
            "Cannot find home directory.",
        ))?;
        let logs = home_dir.join("Library/Logs/Paneru");
        Ok(Self {
            bin_path: exe_path().ok_or(Error::new(
                ErrorKind::NotFound,
                "Cannot find current executable path.",
            ))?,
            raw: launchctl::Service::builder()
                .name(name)
                .uid(unsafe { libc::getuid() }.to_string())
                .plist_path(format!(
                    "{home}/Library/LaunchAgents/{name}.plist",
                    home = home_dir.display()
                ))
                .out_log_path(logs.join("stdout.log").to_string_lossy())
                .error_log_path(logs.join("stderr.log").to_string_lossy())
                .build(),
            home_dir,
        })
    }

    /// Returns the path to the launchd plist file for this service.
    #[must_use]
    pub fn plist_path(&self) -> &Path {
        Path::new(&self.raw.plist_path)
    }

    /// Checks if the service is currently installed (i.e., its plist file exists).
    #[must_use]
    pub fn is_installed(&self) -> bool {
        self.plist_path().is_file()
    }

    /// Installs the service as a launch agent by writing its plist file.
    /// If the service is already installed, a warning is logged, and installation is skipped.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service is installed successfully or already exists, otherwise `Err(Error)` if a file system error occurs.
    pub fn install(&self) -> Result<()> {
        self.create_log_files()?;
        let plist_path = self.plist_path();
        let dir = plist_path.parent().ok_or(Error::last_os_error())?;
        if !dir.exists() {
            fs::create_dir_all(dir)?;
        }

        if self.is_installed() {
            warn!(
                "existing launch agent detected at `{}`, skipping installation",
                plist_path.display()
            );
            return Ok(());
        }

        let mut plist = fs::File::create(plist_path)?;
        plist.write_all(self.launchd_plist().as_bytes())?;
        info!("installed launch agent to `{}`", plist_path.display());
        info!("check logs in ~/Library/Logs/Paneru for potential error messages");
        Ok(())
    }

    /// Uninstalls the service by removing its plist file.
    /// If the service is not installed, a warning is logged, and uninstallation is skipped.
    /// It also attempts to stop the service before removing the file.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service is uninstalled successfully or not found, otherwise `Err(Error)` if a file system error occurs.
    pub fn uninstall(&self) -> Result<()> {
        let plist_path = self.plist_path();
        if !self.is_installed() {
            warn!(
                "no launch agent detected at `{}`, skipping uninstallation",
                plist_path.display(),
            );
            return Ok(());
        }

        if let Err(e) = self.stop() {
            warn!("failed to stop service: {e:?}");
        }

        fs::remove_file(plist_path)?;
        info!(
            "removed existing launch agent at `{}`",
            plist_path.display()
        );
        Ok(())
    }

    /// Reinstalls the service by first uninstalling it and then installing it again.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service is reinstalled successfully, otherwise `Err(Error)` from underlying install/uninstall operations.
    pub fn reinstall(&self) -> Result<()> {
        self.uninstall()?;
        self.install()
    }

    /// Starts the service using `launchctl`.
    /// If the service is not installed, it will be installed first.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service starts successfully, otherwise `Err(Error)` from `launchctl`.
    pub fn start(&self) -> Result<()> {
        if !self.is_installed() {
            self.install()?;
        }
        info!("starting service...");
        self.create_log_files()?;
        // Preserve all other installed LaunchAgent policy, including the
        // companion's on-demand/login behavior, during the one-time migration.
        let installed = fs::read_to_string(self.plist_path())?;
        let migrated = migrate_log_paths(&installed, &self.raw);
        if migrated != installed {
            fs::write(self.plist_path(), migrated)?;
            if self.is_bootstrapped()? {
                Self::run_launchctl(&["bootout", self.raw.service_target.as_str()])?;
            }
        }
        for args in start_commands(&self.raw, self.is_bootstrapped()?) {
            Self::run_launchctl(&args)?;
        }
        info!("service started");
        Ok(())
    }

    fn create_log_files(&self) -> Result<()> {
        prepare_logs(&self.home_dir.join("Library/Logs/Paneru"))
    }

    fn is_bootstrapped(&self) -> Result<bool> {
        let output = Self::launchctl(&["print", self.raw.service_target.as_str()])?;
        Ok(output.status.success())
    }

    fn run_launchctl(args: &[&str]) -> Result<()> {
        let output = Self::launchctl(args)?;
        if output.status.success() {
            return Ok(());
        }

        Err(Error::other(format!(
            "launchctl {} failed with {}: {}",
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )))
    }

    fn launchctl(args: &[&str]) -> Result<Output> {
        Command::new("/bin/launchctl").args(args).output()
    }

    /// Stops the service using `launchctl`.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service stops successfully, otherwise `Err(Error)` from `launchctl`.
    pub fn stop(&self) -> Result<()> {
        info!("stopping service...");
        self.raw.stop()?;
        info!("service stopped");
        Ok(())
    }

    /// Restarts the service by first stopping it and then starting it again.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the service restarts successfully, otherwise `Err(Error)` from underlying stop/start operations.
    pub fn restart(&self) -> Result<()> {
        self.stop()?;
        self.start()
    }

    /// Spawns a detached `paneru restart` subprocess.
    /// Used by the in-daemon restart command so launchctl stop/start runs outside
    /// the process being stopped.
    pub fn request_restart() -> Result<()> {
        let bin_path = exe_path().ok_or(Error::new(
            ErrorKind::NotFound,
            "Cannot find current executable path.",
        ))?;
        Command::new(bin_path)
            .arg("restart")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        Ok(())
    }

    /// Generates the content of the launchd plist file for this service.
    /// This string is formatted with the service name, executable path, and log paths.
    #[must_use]
    pub fn launchd_plist(&self) -> String {
        let xdg_config_home = env::var("XDG_CONFIG_HOME")
            .unwrap_or_else(|_| format!("{}/.config", self.home_dir.display()));
        let rust_log = env::var("RUST_LOG").unwrap_or_else(|_| "info".to_string());
        format!(
            include_str!("../../assets/launchd.plist"),
            name = xml_text(&self.raw.name),
            bin_path = xml_text(&self.bin_path.to_string_lossy()),
            out_log_path = xml_text(&self.raw.out_log_path),
            error_log_path = xml_text(&self.raw.error_log_path),
            xdg_config_home = xml_text(&xdg_config_home),
            rust_log = xml_text(&rust_log),
        )
    }
}

fn migrate_log_paths(plist: &str, service: &launchctl::Service) -> String {
    plist
        .replace(
            &format!("/tmp/{}_{}.err.log", service.name, service.uid),
            &xml_text(&service.error_log_path),
        )
        .replace(
            &format!("/tmp/{}_{}.out.log", service.name, service.uid),
            &xml_text(&service.out_log_path),
        )
}

fn xml_text(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// Open through the private directory descriptor so neither precreated links
/// nor a directory rename can redirect file creation. Never truncate old logs.
fn prepare_logs(directory: &Path) -> Result<()> {
    let parent = directory
        .parent()
        .ok_or_else(|| Error::other("missing log parent"))?;
    fs::create_dir_all(parent)?;
    match fs::DirBuilder::new().mode(0o700).create(directory) {
        Ok(()) => {}
        Err(err) if err.kind() == ErrorKind::AlreadyExists => {}
        Err(err) => return Err(err),
    }
    let dir = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory)?;
    check_log_owner(&dir, true)?;
    for name in [c"stdout.log", c"stderr.log"] {
        // SAFETY: dir is an open directory, name is NUL-terminated, and mode
        // is supplied for O_CREAT. The returned descriptor is owned below.
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY
                    | libc::O_APPEND
                    | libc::O_CREAT
                    | libc::O_NOFOLLOW
                    | libc::O_NONBLOCK
                    | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(Error::last_os_error());
        }
        // SAFETY: openat returned a new, valid descriptor owned by this File.
        let file = unsafe { fs::File::from_raw_fd(fd) };
        check_log_owner(&file, false)?;
    }
    Ok(())
}

fn check_log_owner(file: &fs::File, directory: bool) -> Result<()> {
    let metadata = file.metadata()?;
    // SAFETY: getuid has no preconditions.
    if metadata.uid() != unsafe { libc::getuid() }
        || if directory {
            !metadata.is_dir()
        } else {
            !metadata.is_file() || metadata.nlink() != 1
        }
    {
        return Err(Error::new(
            ErrorKind::PermissionDenied,
            "unsafe log ownership or file type",
        ));
    }
    // SAFETY: file owns this valid descriptor; ownership was checked above.
    if unsafe { libc::fchmod(file.as_raw_fd(), if directory { 0o700 } else { 0o600 }) } != 0 {
        return Err(Error::last_os_error());
    }
    Ok(())
}

fn start_commands(service: &launchctl::Service, bootstrapped: bool) -> Vec<Vec<&str>> {
    if bootstrapped {
        vec![vec!["kickstart", service.service_target.as_str()]]
    } else {
        vec![
            vec!["enable", service.service_target.as_str()],
            vec![
                "bootstrap",
                service.domain_target.as_str(),
                service.plist_path.as_str(),
            ],
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::{migrate_log_paths, prepare_logs, start_commands};
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
        path::Path,
        time::{SystemTime, UNIX_EPOCH},
    };

    fn with_logs(test: impl FnOnce(&Path)) {
        let root = std::env::temp_dir().join(format!(
            "paneru-log-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _cleanup = scopeguard::guard(root.clone(), |path| {
            let _ = fs::remove_dir_all(path);
        });
        fs::create_dir(&root).unwrap();
        test(&root.join("Paneru"));
    }

    #[test]
    fn logs_are_private_and_existing_output_is_preserved() {
        with_logs(|dir| {
            prepare_logs(dir).unwrap();
            let file = dir.join("stdout.log");
            fs::write(&file, "existing output").unwrap();
            fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
            prepare_logs(dir).unwrap();
            assert_eq!(fs::read_to_string(&file).unwrap(), "existing output");
            assert_eq!(
                fs::metadata(dir).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(file).unwrap().permissions().mode() & 0o777,
                0o600
            );
        });
    }

    #[test]
    fn logs_reject_symlinks_hardlinks_and_directory_links() {
        with_logs(|dir| {
            fs::create_dir(dir).unwrap();
            let file = dir.join("stdout.log");
            let target = dir.parent().unwrap().join("outside");
            symlink(&target, &file).unwrap();
            assert!(prepare_logs(dir).is_err());
            assert!(!target.exists());
            fs::remove_file(&file).unwrap();
            fs::write(&target, "keep").unwrap();
            fs::hard_link(&target, &file).unwrap();
            assert!(prepare_logs(dir).is_err());
            assert_eq!(fs::read_to_string(&target).unwrap(), "keep");
            fs::remove_dir_all(dir).unwrap();
            symlink(dir.parent().unwrap(), dir).unwrap();
            assert!(prepare_logs(dir).is_err());
        });
    }

    fn service() -> launchctl::Service {
        launchctl::Service::builder()
            .name("com.github.karinushka.paneru")
            .uid("501")
            .plist_path("/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist")
            .build()
    }

    #[test]
    fn log_migration_preserves_launch_policy_and_escapes_paths() {
        let mut service = service();
        service.error_log_path = "/Users/A&B/Library/Logs/Paneru/stderr.log".to_owned();
        service.out_log_path = "/Users/A&B/Library/Logs/Paneru/stdout.log".to_owned();
        let original = "<key>RunAtLoad</key><false/><string>/tmp/com.github.karinushka.paneru_501.err.log</string><string>/tmp/com.github.karinushka.paneru_501.out.log</string>";
        let migrated = migrate_log_paths(original, &service);
        assert!(migrated.starts_with("<key>RunAtLoad</key><false/>"));
        assert!(migrated.contains("/Users/A&amp;B/Library/Logs/Paneru/stderr.log"));
        assert!(!migrated.contains("/tmp/"));
        assert_eq!(migrate_log_paths(&migrated, &service), migrated);
    }

    #[test]
    fn start_kickstarts_a_bootstrapped_service_by_service_target() {
        assert_eq!(
            start_commands(&service(), true),
            vec![vec!["kickstart", "gui/501/com.github.karinushka.paneru"]]
        );
    }

    #[test]
    fn start_enables_and_bootstraps_an_unloaded_service() {
        assert_eq!(
            start_commands(&service(), false),
            vec![
                vec!["enable", "gui/501/com.github.karinushka.paneru"],
                vec![
                    "bootstrap",
                    "gui/501",
                    "/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist"
                ]
            ]
        );
    }
}
