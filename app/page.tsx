"use client";

import { useEffect, useRef, useState } from "react";
import Skeleton from "react-loading-skeleton";
import "react-loading-skeleton/dist/skeleton.css";
import {
  buildRotationMessage,
  TEST_STEP_DEGREES,
  toHex,
} from "./om3-protocol";

const SERVICE_UUID = "0000fff0-0000-1000-8000-00805f9b34fb";
const NOTIFY_UUID = "0000fff4-0000-1000-8000-00805f9b34fb";
const WRITE_UUID = "0000fff5-0000-1000-8000-00805f9b34fb";

type GattCharacteristic = EventTarget & {
  properties: {
    write?: boolean;
    writeWithoutResponse?: boolean;
  };
  value?: DataView;
  startNotifications(): Promise<GattCharacteristic>;
  stopNotifications(): Promise<GattCharacteristic>;
  writeValue?(value: ArrayBuffer): Promise<void>;
  writeValueWithoutResponse?(value: ArrayBuffer): Promise<void>;
};

type GattService = {
  getCharacteristic(uuid: string): Promise<GattCharacteristic>;
};

type GattServer = {
  connected: boolean;
  connect(): Promise<GattServer>;
  disconnect(): void;
  getPrimaryService(uuid: string): Promise<GattService>;
};

type BluetoothDevice = EventTarget & {
  name?: string;
  gatt?: GattServer;
};

type BluetoothNavigator = Navigator & {
  bluetooth?: {
    requestDevice(options: {
      acceptAllDevices: true;
      optionalServices: string[];
    }): Promise<BluetoothDevice>;
  };
};

type BleState = "disconnected" | "connecting" | "ready" | "error";
type CameraState = "off" | "starting" | "ready" | "error";

type LogEntry = {
  id: number;
  text: string;
  time: string;
};

export default function Home() {
  const [bleState, setBleState] = useState<BleState>("disconnected");
  const [deviceName, setDeviceName] = useState("未连接");
  const [safeToMove, setSafeToMove] = useState(false);
  const [cameraState, setCameraState] = useState<CameraState>("off");
  const [cameras, setCameras] = useState<MediaDeviceInfo[]>([]);
  const [selectedCamera, setSelectedCamera] = useState("");
  const [logs, setLogs] = useState<LogEntry[]>([
    { id: 0, time: "待机", text: "请先完成配平，再连接 OM3。" },
  ]);

  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const deviceRef = useRef<BluetoothDevice | null>(null);
  const notifyRef = useRef<GattCharacteristic | null>(null);
  const writeRef = useRef<GattCharacteristic | null>(null);
  const logIdRef = useRef(1);

  const addLog = (text: string) => {
    const entry = {
      id: logIdRef.current,
      time: new Date().toLocaleTimeString("zh-CN", {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      }),
      text,
    };
    logIdRef.current += 1;
    setLogs((current) => [entry, ...current].slice(0, 7));
  };

  useEffect(() => {
    return () => {
      streamRef.current?.getTracks().forEach((track) => track.stop());
      if (deviceRef.current?.gatt?.connected) {
        deviceRef.current.gatt.disconnect();
      }
    };
  }, []);

  const handleNotification = (event: Event) => {
    const characteristic = event.target as GattCharacteristic;
    if (!characteristic.value) return;
    const bytes = new Uint8Array(
      characteristic.value.buffer,
      characteristic.value.byteOffset,
      characteristic.value.byteLength,
    );
    addLog(`OM3 通知 · ${toHex(bytes).slice(0, 47)}${bytes.length > 16 ? " …" : ""}`);
  };

  const resetBle = (message?: string) => {
    writeRef.current = null;
    notifyRef.current = null;
    deviceRef.current = null;
    setBleState("disconnected");
    setDeviceName("未连接");
    setSafeToMove(false);
    if (message) addLog(message);
  };

  const connectOM3 = async () => {
    const bluetooth = (navigator as BluetoothNavigator).bluetooth;
    if (!bluetooth) {
      setBleState("error");
      addLog("当前浏览器不支持 Web Bluetooth；请使用 Mac 版 Chrome。 ");
      return;
    }

    setBleState("connecting");
    addLog("正在打开 BLE 设备选择器…");

    try {
      const device = await bluetooth.requestDevice({
        acceptAllDevices: true,
        optionalServices: [SERVICE_UUID],
      });
      if (!device.gatt) throw new Error("该设备没有可用的 GATT 服务");

      deviceRef.current = device;
      device.addEventListener("gattserverdisconnected", () => {
        resetBle("OM3 已断开，运动控制已锁定。");
      });

      addLog(`已选择 ${device.name || "未命名 BLE 设备"}，正在连接…`);
      const server = await device.gatt.connect();
      const service = await server.getPrimaryService(SERVICE_UUID);
      const [notifyCharacteristic, writeCharacteristic] = await Promise.all([
        service.getCharacteristic(NOTIFY_UUID),
        service.getCharacteristic(WRITE_UUID),
      ]);

      notifyCharacteristic.addEventListener("characteristicvaluechanged", handleNotification);
      await notifyCharacteristic.startNotifications();
      notifyRef.current = notifyCharacteristic;
      writeRef.current = writeCharacteristic;
      setDeviceName(device.name || "OM3");
      setBleState("ready");
      addLog("FFF0 / FFF4 / FFF5 已就绪；请确认安全条件后再点动。");
    } catch (error) {
      deviceRef.current?.gatt?.disconnect();
      writeRef.current = null;
      notifyRef.current = null;
      setBleState("error");
      setDeviceName("连接失败");
      addLog(`连接失败 · ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  const disconnectOM3 = async () => {
    try {
      if (notifyRef.current) await notifyRef.current.stopNotifications();
    } catch {
      // The peripheral may already be gone; disconnect is still safe to finish.
    }
    if (deviceRef.current?.gatt?.connected) deviceRef.current.gatt.disconnect();
    resetBle("已主动断开 OM3。");
  };

  const writeMessage = async (message: Uint8Array) => {
    const characteristic = writeRef.current;
    if (!characteristic || bleState !== "ready") {
      throw new Error("OM3 尚未就绪");
    }

    for (let offset = 0; offset < message.length; offset += 20) {
      const chunk = message.slice(offset, offset + 20);
      const buffer = chunk.buffer.slice(
        chunk.byteOffset,
        chunk.byteOffset + chunk.byteLength,
      ) as ArrayBuffer;

      if (
        characteristic.properties.writeWithoutResponse &&
        characteristic.writeValueWithoutResponse
      ) {
        await characteristic.writeValueWithoutResponse(buffer);
      } else if (characteristic.writeValue) {
        await characteristic.writeValue(buffer);
      } else {
        throw new Error("FFF5 不支持写入");
      }
    }
  };

  const nudge = async (yawDegrees: number, pitchDegrees: number, label: string) => {
    if (!safeToMove) {
      addLog("控制被安全锁拦截：请先确认负载已配平且线缆无拉扯。");
      return;
    }

    const message = buildRotationMessage({
      yaw: Math.round(yawDegrees * 10),
      pitch: Math.round(pitchDegrees * 10),
    });

    try {
      await writeMessage(message);
      addLog(`${label} · 相对 ${TEST_STEP_DEGREES}° / 1.0 秒`);
    } catch (error) {
      addLog(`写入失败 · ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  const stopMotion = async () => {
    const message = buildRotationMessage({
      yaw: 0,
      pitch: 0,
      roll: 0,
      mode: "speed",
      time: 0,
    });

    try {
      await writeMessage(message);
      addLog("已发送零速度停止指令。");
    } catch (error) {
      addLog(`停止指令失败 · ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  const stopCamera = () => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setCameraState("off");
    addLog("USB 摄像头预览已停止。");
  };

  const startCamera = async (deviceId?: string) => {
    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraState("error");
      addLog("当前浏览器无法访问摄像头。");
      return;
    }

    setCameraState("starting");
    streamRef.current?.getTracks().forEach((track) => track.stop());

    try {
      const video: MediaTrackConstraints = deviceId
        ? { deviceId: { exact: deviceId }, width: { ideal: 1920 }, height: { ideal: 1080 } }
        : { width: { ideal: 1920 }, height: { ideal: 1080 } };
      const stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
      streamRef.current = stream;
      if (videoRef.current) {
        videoRef.current.srcObject = stream;
        await videoRef.current.play();
      }

      const available = (await navigator.mediaDevices.enumerateDevices()).filter(
        (device) => device.kind === "videoinput",
      );
      const activeId = stream.getVideoTracks()[0]?.getSettings().deviceId || deviceId || "";
      setCameras(available);
      setSelectedCamera(activeId);
      setCameraState("ready");
      addLog(`摄像头已开始预览 · ${stream.getVideoTracks()[0]?.label || "视频输入"}`);
    } catch (error) {
      streamRef.current = null;
      setCameraState("error");
      addLog(`摄像头启动失败 · ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  const bleReady = bleState === "ready";
  const controlsEnabled = bleReady && safeToMove;

  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="#top" aria-label="OM3 联调台首页">
          <span className="brand-mark">O3</span>
          <span>
            <strong>OM3 Lab</strong>
            <small>Mac mini 联调台</small>
          </span>
        </a>
        <div className="system-status" aria-label="设备状态">
          <span className={`status-chip ${bleReady ? "is-live" : ""}`}>
            <i /> BLE · {bleReady ? deviceName : "待连接"}
          </span>
          <span className={`status-chip ${cameraState === "ready" ? "is-live" : ""}`}>
            <i /> USB 画面 · {cameraState === "ready" ? "在线" : "待启动"}
          </span>
        </div>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-copy">
            <p className="eyebrow">BLE CONTROL / UVC PREVIEW</p>
            <h1>先证明控制链路，<br />再装上摄像头。</h1>
            <p className="hero-lede">
              这个页面只做安全的 5° 点动测试。OM3 负责运动，USB 摄像头直接把画面送入 Mac mini，两条链路彼此独立。
            </p>
          </div>
          <div className="connection-map" aria-label="设备连接关系">
            <div className="map-node map-host">
              <span>主机</span>
              <strong>Mac mini</strong>
            </div>
            <div className="map-links">
              <div><b>BLE 5.0</b><span>无线控制</span></div>
              <div><b>USB</b><span>视频输入</span></div>
            </div>
            <div className="map-targets">
              <div className="map-node"><span>运动</span><strong>DJI OM3</strong></div>
              <div className="map-node"><span>画面</span><strong>USB Camera</strong></div>
            </div>
          </div>
        </section>

        <section className="workbench" aria-label="联调工作台">
          <article className="panel camera-panel">
            <div className="panel-heading">
              <div>
                <span className="step-number">01</span>
                <p className="panel-kicker">USB CAMERA</p>
                <h2>画面预览</h2>
              </div>
              <span className={`state-pill state-${cameraState}`}>
                {cameraState === "ready" ? "LIVE" : cameraState === "starting" ? "STARTING" : "OFFLINE"}
              </span>
            </div>

            <div className="camera-stage">
              <video
                ref={videoRef}
                muted
                playsInline
                autoPlay
                className={cameraState === "ready" ? "is-visible" : ""}
              />
              {cameraState === "starting" ? (
                <div className="camera-skeleton" aria-label="正在启动摄像头">
                  <Skeleton height="100%" baseColor="#15191a" highlightColor="#242a2b" />
                </div>
              ) : cameraState !== "ready" ? (
                <div className="camera-placeholder">
                  <div className="focus-frame"><span /></div>
                  <p>{cameraState === "error" ? "摄像头不可用" : "等待 USB 视频输入"}</p>
                  <small>摄像头线直接连接 Mac mini</small>
                </div>
              ) : null}
              <div className="preview-overlay">
                <span>UVC / LOCAL PREVIEW</span>
                <span>{cameraState === "ready" ? "● REC READY" : "NO SIGNAL"}</span>
              </div>
            </div>

            <div className="camera-toolbar">
              <label>
                <span>视频设备</span>
                <select
                  value={selectedCamera}
                  disabled={cameras.length === 0}
                  onChange={(event) => {
                    const id = event.target.value;
                    setSelectedCamera(id);
                    void startCamera(id);
                  }}
                >
                  {cameras.length === 0 ? (
                    <option value="">启动后显示设备</option>
                  ) : (
                    cameras.map((camera, index) => (
                      <option key={camera.deviceId} value={camera.deviceId}>
                        {camera.label || `摄像头 ${index + 1}`}
                      </option>
                    ))
                  )}
                </select>
              </label>
              {cameraState === "ready" ? (
                <button className="button button-secondary" onClick={stopCamera}>停止预览</button>
              ) : (
                <button
                  className="button button-primary"
                  disabled={cameraState === "starting"}
                  onClick={() => void startCamera()}
                >
                  允许并启动摄像头
                </button>
              )}
            </div>
          </article>

          <article className="panel control-panel">
            <div className="panel-heading">
              <div>
                <span className="step-number">02</span>
                <p className="panel-kicker">BLUETOOTH LE</p>
                <h2>OM3 点动控制</h2>
              </div>
              <span className={`state-pill state-${bleState}`}>
                {bleReady ? "READY" : bleState === "connecting" ? "CONNECTING" : "LOCKED"}
              </span>
            </div>

            <div className="ble-connection">
              <div>
                <span className="label">当前设备</span>
                <strong>{deviceName}</strong>
                <small>{bleReady ? "FFF0 · FFF4 · FFF5 已发现" : "用 Chrome 打开 BLE 设备选择器"}</small>
              </div>
              {bleReady ? (
                <button className="button button-secondary" onClick={() => void disconnectOM3()}>断开</button>
              ) : (
                <button
                  className="button button-primary"
                  disabled={bleState === "connecting"}
                  onClick={() => void connectOM3()}
                >
                  {bleState === "connecting" ? "连接中…" : "扫描并连接 OM3"}
                </button>
              )}
            </div>

            <label className={`safety-check ${safeToMove ? "is-checked" : ""}`}>
              <input
                type="checkbox"
                checked={safeToMove}
                disabled={!bleReady}
                onChange={(event) => setSafeToMove(event.target.checked)}
              />
              <span className="check-box" aria-hidden="true">✓</span>
              <span>
                <strong>负载已配平，线缆在 ±5° 内无拉扯</strong>
                <small>确认后才会解锁运动按钮</small>
              </span>
            </label>

            <div className="motion-block">
              <div className="motion-meta">
                <span>相对角度</span><b>5°</b>
                <span>完成时间</span><b>1.0s</b>
              </div>
              <div className="d-pad" aria-label="OM3 四向点动">
                <button
                  className="pad-button pad-up"
                  disabled={!controlsEnabled}
                  aria-label="俯仰增加 5 度"
                  onClick={() => void nudge(0, TEST_STEP_DEGREES, "俯仰 +")}
                >
                  <span>↑</span><small>PITCH +</small>
                </button>
                <button
                  className="pad-button pad-left"
                  disabled={!controlsEnabled}
                  aria-label="偏航减少 5 度"
                  onClick={() => void nudge(-TEST_STEP_DEGREES, 0, "偏航 −")}
                >
                  <span>←</span><small>YAW −</small>
                </button>
                <button
                  className="pad-button pad-stop"
                  disabled={!bleReady}
                  aria-label="停止运动"
                  onClick={() => void stopMotion()}
                >
                  <span>■</span><small>STOP</small>
                </button>
                <button
                  className="pad-button pad-right"
                  disabled={!controlsEnabled}
                  aria-label="偏航增加 5 度"
                  onClick={() => void nudge(TEST_STEP_DEGREES, 0, "偏航 +")}
                >
                  <span>→</span><small>YAW +</small>
                </button>
                <button
                  className="pad-button pad-down"
                  disabled={!controlsEnabled}
                  aria-label="俯仰减少 5 度"
                  onClick={() => void nudge(0, -TEST_STEP_DEGREES, "俯仰 −")}
                >
                  <span>↓</span><small>PITCH −</small>
                </button>
              </div>
              <p className="axis-note">若实际安装方向相反，以 YAW / PITCH 的正负号为准。</p>
            </div>

            <div className="event-log">
              <div className="log-heading">
                <span>事件记录</span>
                <button onClick={() => setLogs([])}>清空</button>
              </div>
              <ol aria-live="polite">
                {logs.length === 0 ? (
                  <li className="empty-log">暂无记录</li>
                ) : (
                  logs.map((entry) => (
                    <li key={entry.id}>
                      <time>{entry.time}</time><span>{entry.text}</span>
                    </li>
                  ))
                )}
              </ol>
            </div>
          </article>
        </section>

        <section className="gate-section">
          <div className="section-title">
            <p className="eyebrow">GO / NO-GO GATES</p>
            <h2>今天只验证四件事</h2>
            <p>任一步失败都先停在当前阶段，不要继续加装和扩大运动范围。</p>
          </div>
          <div className="gate-grid">
            <div className="gate-card"><b>01</b><strong>发现</strong><p>Chrome 选择器里出现 OM3，旧手机已断开。</p></div>
            <div className="gate-card"><b>02</b><strong>握手</strong><p>连接后找到 FFF0 服务、FFF4 通知和 FFF5 写入。</p></div>
            <div className="gate-card"><b>03</b><strong>点动</strong><p>四个方向各测试一次 5°，停止指令立即生效。</p></div>
            <div className="gate-card"><b>04</b><strong>画面</strong><p>USB 摄像头预览连续，点动时线缆不绷紧、不抖动。</p></div>
          </div>
        </section>

        <section className="safety-strip">
          <div className="safety-icon">!</div>
          <div>
            <strong>实验性控制协议</strong>
            <p>OM3 的 BLE 控制并非 DJI 官方公开接口。请先用 DJI Mimo 完成激活，只发送已验证的小角度运动包，不进行固件或未知特征写入。</p>
          </div>
          <a href="https://github.com/alkersan/om-research" target="_blank" rel="noreferrer">协议依据 ↗</a>
        </section>
      </main>

      <footer className="site-footer">
        <span>OM3 Lab · 本地设备联调</span>
        <span>画面不经过 OM3 · OM3 USB-C 仅供电</span>
      </footer>
    </div>
  );
}
