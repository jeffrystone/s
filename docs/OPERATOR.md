# Руководство оператора: команды MANUAL по WebSocket

Сервер: `Nodes.start_dashboard(env_ref)`; см. **`start_dashboard(...; auto_step=true, sim=Ref(DashboardSimHandles(task, settings)))`** в разделе ниже для драйва **`step!`** из цикла WebSocket.

## Общий формат


| Поле     | Описание                                |
| -------- | --------------------------------------- |
| `action` | Строковое имя действия (`add_node`, …). |
| др. поля | Зависят от действия (см. ниже).         |


Идентификаторы узлов и шрамов передаются как число или строка; на сервере приводятся к `UInt64`.

## Запуск с авто-`step!` из WebSocket

По умолчанию клиент только получает снимки; **`step!`** нужно вызывать во внешнем цикле. Чтобы продвигать симуляцию **после каждого снимка в сессии** (до **`paused`** включительно блокирующая логика `step!`):

```julia
env_ref = Ref(env)
sim = Ref(Nodes.DashboardSimHandles(task, settings))
serverws, http_task = Nodes.start_dashboard(env_ref; auto_step = true, sim = sim)
```

Число итераций **`step!` за один период** берётся из **`env.ws_burst_steps`** (`1` при создании окружения, меняется **`set_tick_burst`**, верх **`Settings.dashboard_burst_steps_max`**).

## Два текстовых кадра WebSocket (`events_delta`)

По умолчанию **`send_event_delta=false`**: каждый интервал отправляется **одно** текстовое сообщение — полный JSON снимка `state_snapshot` (совместимо с произвольными потребителями).

При **`send_event_delta=true`** в **`start_dashboard`**, за один интервал отправляются **подряд два** сообщения:

1. Полный JSON снимок (как выше).
2. Объект с полем **`delta: true`**: **`seq`** (монотонный счётчик кадров сессии), **`tick`** (значение `env.tick` **после** локального burst `step!` этого интервала), **`t_server_ms`**, **`broadcast_interval_ms`** (оценка `interval · 1000` мс), **`events_append`** — записи журнала `recent_events`, добавленные **после** момента сериализации первого сообщения до конца burst `step!` на этом интервале.

Страница **`web/index.html`** объединяет дельту с хвостом из полного снимка в кольцевой буфер и рисует лучи с учётом `performance.now()`.

Пример запуска с дельтой:

```julia
Nodes.start_dashboard(env_ref; auto_step=true, sim=sim, send_event_delta=true)
```

### `broadcast_metric_deltas`

При **`broadcast_metric_deltas=true`** первый текстовый кадр (полный JSON) проходит через **`snapshot_json_with_broadcast_metric_deltas`**, в объект добавляются:

- **`event_time_delta_s`**: секунды wall-time по типам событий **с прошлой рассылки** кадра сессии (разница кумулятивных `env.event_time_s`),
- **`per_node_time_delta_s`**: то же по узлам (`env.per_node_time_s`, ключи — строковые id).

Семантика **`event_time_s`** / **`per_node_time_s`** в корне снимка не меняется (кумулятив за сессию). На **первом** кадре WebSocket-сессии значения Δ совпадают с накопленным с начала симулятора (предыдущий буфер `nothing`).

```julia
Nodes.start_dashboard(env_ref;
    auto_step = true,
    sim = sim,
    broadcast_metric_deltas = true)
```

Клиент **`web/dashboard_app.js`**: столбики HUD предпочитают **`event_time_delta_s`**, если там есть положительные значения; столбики по узлам над сценой строятся по **`per_node_time_s`** (топ-K).

## Действия

### `add_node`

Создать узел с начальными `hp`/`mp` и параметрами задачи (для Pollard — `params` с ключами `N`, `start_x`, `poly_coeff` и т.д.).

```json
{"action":"add_node","params":{"N":"221","start_x":15,"poly_coeff":7},"hp":120,"mp":50}
```

### `delete_node`

Удалить узел по `node_id` из популяции (фильтрация вектора `env.nodes`). Запись шрама при удалении **не выполняется** автоматически в текущей реализации движка.

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

### `set_tick_burst`

Сколько раз за один интервал отправки WebSocket выполняется **`step!`**, когда включён **`auto_step`** у `start_dashboard` (до клампа **`0..dashboard_burst_steps_max`**). Удобно менять ползунком «шагов за кадр» в `web/index.html`.

Эквивалентные поля **`burst_steps`** или короткий **`burst`**:

```json
{"action":"set_tick_burst","burst_steps":8}
{"action":"set_tick_burst","burst":8}
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

Дополнительно в JSON транслируются **`mean_D_history`** (копия буфера среднего `D` после проходов ANALYSIS) и **`exploration_ratio_history`** (на тех же отсечках ANALYSIS — доля `exploration_budget` в сумме бюджетов после правок застоя/прогресса в `analysis_pass!`; на клиенте вторая кривая на том же канвасе, что средний `D`), **`ws_burst_steps`**, **`metric_l34_buffer_len`**, **`recent_events`**, **`manual_audit_tail`**, **`leader_node`**, **`paused`**, **`t_wall_ms`**, множители внимания, **`event_time_s`** / **`per_node_time_s`** (кумулятив wall-time симулятора), в шрамах — поле `id` для связки с `clear_scar`; при **`broadcast_metric_deltas=true`** — см. там же ключи **`event_time_delta_s`** и **`per_node_time_delta_s`**.

Дополнительные события между полными JSON и второй кадр WebSocket см. раздел «Два текстовых кадра WebSocket» при **`send_event_delta=true`**.

В `web/index.html` чекбоксы слоёв сцены (шрамы, лучи событий, спящие узлы) запоминают состояние в **`localStorage`** (`nodes_layer_*`); выбранное число **`burst_steps`** можно хранить в **`nodes_burst_steps`**. ПКМ по узлу или шраму на canvas открывает контекстное меню (primary/secondary id, удаление, новый узел через модалку Pollard, принудительный резонанс при двух разных id в полях). **Esc** закрывает меню и модалку.

### Приоритет ANALYSIS на календарном такте

Для тактов с `tick % analysis_interval == 0` приоритет события **ANALYSIS** не ниже **`Settings.analysis_min_priority_when_due`** (по умолчанию выше максимума клэмпа SHOT в планировщике), чтобы проход **`analysis_pass!`** не подвисал под потоком SHOT/HEAVY/RESONANCE.

В хвосте **`manual_audit_tail`** для действия **`force_resonance`** в последней записи может быть поле **`child_improved`** (`true`/`false`).

## Другие поля симулятора

Размер буфера калибровки L3/L4 настраивается в `Settings` (`analysis_calibration_*`). Калибровка запускается на проходе ANALYSIS при достаточном числе наблюдений пар нормализованных показателей после выстрелов L4.

Апелляции метрик после выстрелов: при **`appeal_unified_dispatch=true`** (умолчанию) после SHOT используется единый диспетчер **`metric_appeal_dispatch_after_shot!`**; при **`appeal_unified_dispatch=false`** сохраняется прежняя ветвь в `handle_shot!`. Опциональная переоценка L3 после L2 при включённом **`appeal_l2_challenge_l3`** задействует те же пороги, что и расширенная связка L2–L4 (`appeal_extend_L2_vs_L3`, `appeal_l2_vs_l3_min_gap`).