#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::{io::{BufRead, BufReader, Write}, process::{Child, ChildStdin, Command, Stdio}, sync::{Mutex, atomic::{AtomicBool, Ordering}}};
use tauri::{Emitter, Manager};
use serde_json::{json, Value};

struct Backend { input: Mutex<Option<ChildStdin>>, process: Mutex<Option<Child>>, alive: AtomicBool }

fn write_request(backend: &Backend, request: &Value) -> Result<(), String> {
    let mut guard = backend.input.lock().map_err(|_| "BACKEND_OFFLINE")?;
    let input = guard.as_mut().ok_or("BACKEND_OFFLINE")?;
    let data = serde_json::to_vec(request).map_err(|_| "INVALID_REQUEST")?;
    if data.len() > 4 * 1024 * 1024 { return Err("INVALID_REQUEST".into()); }
    input.write_all(&data).and_then(|_| input.write_all(b"\n")).and_then(|_| input.flush()).map_err(|_| "BACKEND_OFFLINE".into())
}

#[tauri::command]
fn backend_send(request: Value, backend: tauri::State<Backend>) -> Result<(), String> {
    let allowed = ["hello", "overview", "device", "scan.start", "scan.stop", "image.prepare", "image.inspect", "card.read", "card.apply", "card.restore", "card.classify", "card.export", "recovery.resume", "cancel"];
    if !allowed.contains(&request["method"].as_str().unwrap_or("")) || request["v"] != 1 || !request["id"].is_string() { return Err("INVALID_REQUEST".into()); }
    write_request(&backend, &request)
}

fn start(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let mut command;
    if cfg!(debug_assertions) && std::env::var_os("AIRCARD_PYTHON").is_some() {
        command = Command::new(std::env::var_os("AIRCARD_PYTHON").unwrap());
        command.arg(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../desktop_backend.py"));
    } else {
        let executable = if cfg!(windows) { "aircard-backend.exe" } else { "aircard-backend" };
        command = Command::new(app.path().resource_dir()?.join("backend").join(executable));
    }
    let logs = app.path().app_local_data_dir()?.join("logs");
    std::fs::create_dir_all(&logs)?;
    let log_path = logs.join("backend.log");
    if std::fs::metadata(&log_path).map(|m| m.len() > 2 * 1024 * 1024).unwrap_or(false) {
        let _ = std::fs::rename(&log_path, logs.join("backend.previous.log"));
    }
    let diagnostic = std::fs::OpenOptions::new().create(true).append(true).open(log_path)?;
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::from(diagnostic));
    #[cfg(windows)] { use std::os::windows::process::CommandExt; command.creation_flags(0x08000000); }
    let mut process = command.spawn()?;
    let output = process.stdout.take().ok_or("No stdout")?;
    let backend = app.state::<Backend>();
    *backend.input.lock().unwrap() = process.stdin.take();
    *backend.process.lock().unwrap() = Some(process);
    backend.alive.store(true, Ordering::SeqCst);
    let handle = app.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            let Ok(line) = line else { break };
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if value["id"] == "__shutdown" && value["result"]["safeToExit"] == true {
                    handle.state::<Backend>().input.lock().unwrap().take();
                    if let Some(mut process) = handle.state::<Backend>().process.lock().unwrap().take() { let _ = process.wait(); }
                    handle.exit(0);
                    return;
                }
                let _ = handle.emit("backend-message", value);
            }
        }
        handle.state::<Backend>().alive.store(false, Ordering::SeqCst);
        let _ = handle.emit("backend-message", json!({"v":1,"event":"fatal","code":"BACKEND_OFFLINE"}));
    });
    Ok(())
}

fn main() {
    let builder = tauri::Builder::default();
    #[cfg(feature = "e2e")]
    let builder = builder.plugin(tauri_plugin_wdio::init()).plugin(tauri_plugin_wdio_webdriver::init());
    builder
        .plugin(tauri_plugin_single_instance::init(|app, _, _| { if let Some(window) = app.get_webview_window("main") { let _ = window.set_focus(); } }))
        .plugin(tauri_plugin_dialog::init())
        .manage(Backend { input: Mutex::new(None), process: Mutex::new(None), alive: AtomicBool::new(false) })
        .invoke_handler(tauri::generate_handler![backend_send])
        .setup(|app| { start(app.handle())?; Ok(()) })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let backend = window.state::<Backend>();
                if backend.alive.load(Ordering::SeqCst) {
                    api.prevent_close();
                    let _ = window.emit("backend-message", json!({"v":1,"event":"closing"}));
                    let _ = write_request(&backend, &json!({"v":1,"id":"__shutdown","method":"shutdown","params":{}}));
                }
            }
        })
        .run(tauri::generate_context!()).expect("DittoCard failed to start");
}
