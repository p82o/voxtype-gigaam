# ГигаЧат v3 e2e RNN-T в voxtype — база знаний по установке

# voxtype-gigaam — установка GigaAM v3 e2e RNN-T в voxtype

Проверено на Arch-подобном Linux (CachyOS), окружения niri и GNOME (Wayland), voxtype 1.0.1, Python 3.14.
Модель: https://huggingface.co/ai-sage/GigaAM-v3/tree/e2e_rnnt

## Архитектура

```
PTT-клавиша (push-to-talk) → voxtype daemon → HTTP POST /v1/audio/transcriptions
                                          → gigaam-server (FastAPI, 127.0.0.1:8394)
                                            → GigaAM v3 e2e RNN-T (CPU, torch)
```

- **voxtype** — push-to-talk демон (на Arch: пакет `voxtype-bin`). Конфиг `~/.config/voxtype/config.toml`, user-сервис `voxtype.service`.
- **gigaam-server** — OpenAI-compatible ASR сервер (файл `server.py` из этого репозитория). Каталог `~/.local/share/gigaam/`:
  - `venv/` — torch 2.9.1+cpu (CPU-сборка), torchaudio, transformers 4.57.6, fastapi, uvicorn, pytorch-lightning, pytorch-metric-learning, torch-audiomentations, torch_pitch_shift, torchcodec, torchmetrics, numpy, hydra-core, omegaconf, sentencepiece, pyannote.audio, python-multipart
  - `model/` — файлы модели с HF: `config.json`, `modeling_gigaam.py`, `pytorch_model.bin`, `tokenizer.model`
  - `server.py` — сервер из этого репозитория (с критическим фиксом RLock, см. ниже)
- **watchdog** — health-check каждые 15с, рестарт зависшего сервера.

## Установка (коротко)

```bash
./install.sh && ./verify.sh
```

Ручной вариант (то же самое):
1. Модель — 4 файла с HF-URL выше в `~/.local/share/gigaam/model/`.
2. Venv (torch именно CPU-вариант):
   ```
   python -m venv ~/.local/share/gigaam/venv
   ~/.local/share/gigaam/venv/bin/pip install torch==2.9.1 torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/cpu
   ~/.local/share/gigaam/venv/bin/pip install "transformers==4.57.6" fastapi uvicorn pytorch-lightning pytorch-metric-learning torch-audiomentations torch_pitch_shift torchcodec torchmetrics numpy
   ~/.local/share/gigaam/venv/bin/pip install hydra-core omegaconf sentencepiece pyannote.audio python-multipart
   ```
3. `server.py` из репозитория → `~/.local/share/gigaam/server.py`.
4. `gigaam-server.service` → `~/.config/systemd/user/`, затем:
   `systemctl --user daemon-reload && systemctl --user enable --now gigaam-server.service`
5. Watchdog (обязателен, не опция!): `gigaam-watchdog.sh` → `~/.local/bin/` (chmod +x),
   `gigaam-watchdog.service` и `gigaam-watchdog.timer` → `~/.config/systemd/user/`, затем:
   `systemctl --user daemon-reload && systemctl --user enable --now gigaam-watchdog.timer`
6. voxtype: секции `[whisper]`, `[audio]` из `voxtype-config.toml` (mode=remote, endpoint http://127.0.0.1:8394, max_duration_secs=300, remote_timeout_secs=60).
   **Важно: секцию `[hotkey]` НЕ менять** — у пользователя своя (например `key = "EVTEST_582"`, push_to_talk); F9 в шаблоне — только пример.

## Проверка установки (acceptance test)

Все проверки автоматизированы в `./verify.sh`. Вручную:

```bash
# 1. Жив ли сервер (ожидание: {"status":"ok",...}, HTTP 200)
curl -sf -m 15 http://127.0.0.1:8394/health

# 2. Регресс-тест дедлока: WAV 25.003с, 16кГц, mono (файл чуть БОЛЬШЕ 25с —
#    именно на этой границе был дедлок). Ожидание: HTTP 200 за ~1-8с, не hang.
python3 - <<'EOF'
import wave, struct, math, random
w = wave.open('/tmp/test25s.wav','w')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b''.join(struct.pack('<h', int(12000*math.sin(i*0.05)*random.random())) for i in range(16000*25+50)))
w.close()
EOF
curl -s -m 40 -F file=@/tmp/test25s.wav http://127.0.0.1:8394/v1/audio/transcriptions

# 3. Вачдог поднимает упавший сервер:
systemctl --user stop gigaam-server && ~/.local/bin/gigaam-watchdog.sh
systemctl --user is-active gigaam-server   # ожидание: active

# 4. Реальная речь: официальный тестовый файл авторов модели должен дать
#    отрывок из «Евгения Онегина»
curl -o /tmp/example.wav https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/example.wav
curl -s -F file=@/tmp/example.wav http://127.0.0.1:8394/v1/audio/transcriptions

# 5. Сквозной тест через voxtype:
voxtype transcribe /tmp/example.wav
```

## Грабли (уже наступали — не повторять)

### 1. Дедлок сервера на границе 25с (баг в server.py, критический)
`_transcribe_path()`: аудио длиннее `MAX_SHORT = 25*16000` сэмплов идёт по чанковому пути
и берёт `_lock` второй раз, хотя обработчик запроса уже держит его (строки 76 и 46 старой версии).
`threading.Lock` непереиспользуемый → поток ждёт сам себя вечно, лок захвачен навсегда,
все последующие запросы висят, SIGTERM игнорируется (systemd добивает SIGKILL).
Триггер: запись ровно ~25с (файл получается 25.0xс > MAX_SHORT из-за паддинга).
**Симптом**: транскрипции молча перестают отвечать, сервис «active», рестарт через SIGTERM
зависает до TimeoutStopSec.
**Решение (уже внесено в server.py в репозитории):** `_lock = threading.RLock()`.
**Урок:** никогда не вкладывать повторный захват одного и того же Lock в один поток;
для сериализации инференса вокруг вызовов — только RLock.

### 2. Watchdog: /health должен проходить через тот же лок
`/health` в server.py сознательно обёрнут `with _lock:` — иначе вачдог не видит дедлок
(тредпул FastAPI отвечает health даже когда инференс намертво залип).
Таймер — 15с, в скрипте двойная проверка (fail → sleep 5 → fail → restart):
итого рестарт только после ~35с *непрерывного* простоя.
Запас безопасности измерен: 25с аудио → 1.2с транскрипции (~24× realtime),
180с аудио → 7.4с. Лок держится 1-2с, таймаут curl 15с — ложных рестартов нет,
в т.ч. во время активной записи/транскрипции. Если поменяете модель/железо и скорость
упадёт до ~4× realtime — увеличьте таймаут curl в скрипте.

### 3. Микрофон: контроль усиления (иначе шум в тишине)
Симптом: волна в OSD бурлит в тишине, распознавание грязное.
Причина: ALSA-контролы capture + mic boost на максимуме (на исходной машине было
+30дБ Capture + +30дБ Boost = +60дБ суммарно → шум -20 dBFS).
Метод замера (3с тишины через дефолтный источник):
```bash
timeout 3 parec -d "$(pactl get-default-source)" --rate=16000 --channels=1 --format=s16le \
 | python3 -c "import sys,struct,math; d=sys.stdin.buffer.read(); n=len(d)//2; v=struct.unpack('<%dh'%n,d[:n*2]); rms=(sum(x*x for x in v)/n)**0.5; print('peak %.1f%% rms %.2f%% (%.0f dBFS)'%(max(abs(x) for x in v)/327.68,rms/327.68,20*math.log10(max(rms,1)/32768)))"
```
Цели: шум в тишине rms ≤ ~1% (≤ -40 dBFS), речь пики 30-60% без клиппинга (замер с речью).
Настройка: `amixer -c N sset 'Internal Mic Boost' 1` + `amixer -c N sset Capture 50`
(карту/имена смотреть `cat /proc/asound/cards`, `amixer -c N scontents`).
Обязательно сохранить: `pkexec alsactl store`, иначе собьётся после перезагрузки.

### 4. Длина записи (voxtype обрывал на 25с)
- Лимит клиента: `audio.max_duration_secs` (схема 5..3600, нужен рестарт voxtype).
  Ставили 300. Если voxtype молча обрывает запись — это он, в логе будет
  «WARN Recording timeout (Ns limit)».
- Клиентский таймаут транскрипции: `whisper.remote_timeout_secs` — в `voxtype config schema`
  его НЕТ, править руками в config.toml. Ставили 60.
- Размер: транскрипция ~20-24× realtime (CPU), т.е. 5 мин аудио ≈ 12-15с работы.
  Формула запаса: remote_timeout ≥ длительность/20.
- Есть отдельный режим `voxtype meeting` для непрерывных встреч — если нужен текст длиннее
  лимита, лучше он.

### 5. Модель даёт пустой текст на синтетической речи (espeak TTS)
Симптом: `/health` OK, ошибки в логах нет, `{"text":""}` на аудио.
Метод проверки: официальный тестовый файл авторов модели —
`curl -o /tmp/example.wav https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/example.wav`
и отправить на сервер. На нём модель обязана выдать отрывок из «Евгения Онегина»
(«Ничьих не требуя похвал…»). Если да — установка рабочая; пустой результат
на espeak-сгенерированной русской речи — известная особенность модели, не баг
(живая микрофонная речь распознаётся нормально).
Если пусто и на example.wav: чекпойнт грузится без missing/unexpected keys,
значит проблема в venv-версиях (см. «Установка») или в аудио-пути.

### 6. Версии Python-пакетов (проверено, менять осознанно)
- transformers 5.x НЕ работает: meta-device инициализация роняет FeatureExtractor —
  «Tensor on device cpu is not on the expected device meta». Только 4.57.x.
- Без hydra-core, omegaconf, sentencepiece, pyannote.audio AutoModel падает на
  `check_imports` — modeling_gigaam.py импортирует их напрямую.
- Без python-multipart FastAPI падает на старте: «Form data requires python-multipart».
- torch 2.9.1+cpu проверен; официально рекомендованы 2.8.0, torchcodec 0.7.0.
  torch новее не проверен.

## Полезные команды

```bash
systemctl --user restart gigaam-server          # перезапуск ASR
systemctl --user restart voxtype                # перезапуск клиента (после смены конфига)
journalctl --user -u gigaam-server -f           # логи сервера
journalctl --user -u voxtype -f | grep -E "Recording|Transcrib|ERROR|WARN"
systemctl --user list-timers gigaam-watchdog.timer
voxtype config schema                           # все settable ключи (audio.*, whisper.* — частично)
```
