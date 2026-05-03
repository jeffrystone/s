# Руководство оператора: команды MANUAL по WebSocket

Сервер: `Nodes.start_dashboard(env_ref)`, страница и тот же порт принимают WebSocket-сообщения в виде одного JSON-объекта.

## Общий формат


| Поле     | Описание                                |
| -------- | --------------------------------------- |
| `action` | Строковое имя действия (`add_node`, …). |
| др. поля | Зависят от действия (см. ниже).         |


Идентификаторы узлов и шрамов передаются как число или строка; на сервере приводятся к `UInt64`.

## Действия

### `add_node`

Создать узел с начальными `hp`/`mp` и параметрами задачи (для Pollard — `params` с ключами `N`, `start_x`, `poly_coeff` и т.д.).

```json
{"action":"add_node","params":{"N":"221","start_x":15,"poly_coeff":7},"hp":120,"mp":50}
```

### `delete_node`

Удалить узел по `node_id`; в область добавляется **шрам** с умеренным потенциалом (антидубль по параметрам задачи через `failure_scar_meta`).

```json
{"action":"delete_node","node_id":"3"}
```

### `force_resonance`

Разовое скрещивание пары узлов без проверки кандидатов из очереди. Требуется `hp` и `mp` у инициатора в стиле штатного резонанса (> 0 для `na.mp`, `nb.mp`, `na.hp`).

```json
{"action":"force_resonance","node_a":"1","node_b":"2"}
```

### `clear_scar`

- По `scar_id` (предпочтительно, id из поля снапшота `scars[].id`):  
`{"action":"clear_scar","scar_id":"2"}`
- Или по `scar_index` — индекс **с единицы** в текущем векторе `env.scars`:  
`{"action":"clear_scar","scar_index":1}`

### `set_mp_frozen`

```json
{"action":"set_mp_frozen","node_id":"1","frozen":true}
```

### `pause` / `set_paused`

Остановить окончание `step!` после обработки очереди ручных событий (симулятор «держит состояние»; снапшоты по-прежнему отправляются веб-клиенту).

```json
{"action":"pause"}
```

Или явно:

```json
{"action":"set_paused","paused":true}
```

### `resume`

```json
{"action":"resume"}
```

### `reference_pair`

Подкручивает множители **`attention_tune_alpha`** / **`attention_tune_beta`** / **`attention_tune_gamma`** по отношению к значениям по умолчанию в активной **`Environment`** (поля задаются в коде задачи через `attention_*`; повтор команды суммирует эффект в пределах `clamp`). Опциональные ключи **`boost_alpha`**, **`boost_beta`**, **`boost_gamma`** задают множитель к текущей тройке («эталонная пара» задаёт операторское направление).

```json
{"action":"reference_pair","node_a":"1","node_b":"2","boost_alpha":1.04,"boost_beta":1.05,"boost_gamma":1.04}
```

При заданном в **`Settings`** пути **`attention_tune_persist_path`** множители после успешного применения `reference_pair` **автоматически сохраняются** в этот JSON-файл (атомарная замена). Подробнее — раздел ниже.

## Персистентность `attention_tune_*`

В **`Settings`**:

- **`attention_tune_persist_path`** — строка-путь к файлу или `nothing`. Если указан непустой путь, движок после ручной подстройки тюнов вызывает **`maybe_save_attention_tune!`**: сохранение после **`reference_pair`** и после **`force_resonance`**, если скрещивание дало «улучшающего» потомка (внутренний флаг родителей/ребёнка) при включённой эвристике **`manual_win_tune_enabled`**.
- **`manual_win_tune_eta`**, **`manual_win_tune_gamma_only`** — сила и охват умножения множителей после такого успешного `force_resonance`.

Явный API пакета (можно вызвать **до** `start_dashboard(Ref(env))`):

- **`Nodes.load_attention_tune!(env, path)`** — прочитать JSON и записать три множителя в `env`; `false`, если файла нет.
- **`Nodes.save_attention_tune(env, path)`** — записать текущую тройку (и **`tick_sim`** для отладки).

Автозагрузки при старте дашборда **нет**: при необходимости вызывайте `load_attention_tune!` из своего скрипта запуска. Базовые коэффициенты задачи **`Settings.attention_*`** в файл не попадают.

## Снапшот

Дополнительно в JSON транслируются **`mean_D_history`** (копия буфера среднего `D` после проходов ANALYSIS; клиент использует для sparkline), `metric_l34_buffer_len`, `recent_events`, `manual_audit_tail`, `leader_node`, `paused`, `t_wall_ms`, множители внимания, в шрамах — поле `id` для связки с `clear_scar`.

В хвосте **`manual_audit_tail`** для действия **`force_resonance`** в последней записи может быть поле **`child_improved`** (`true`/`false`).

## Другие поля симулятора

Размер буфера калибровки L3/L4 настраивается в `Settings` (`analysis_calibration_*`). Калибровка запускается на проходе ANALYSIS при достаточном числе наблюдений пар нормализованных показателей после выстрелов L4.