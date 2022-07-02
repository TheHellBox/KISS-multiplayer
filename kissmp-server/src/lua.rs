/*
Lua is not really designed to be used with rust. And async stuff only makes things worse
This API is probably the best I can do without using unsafe.
*/

use crate::server_vehicle::*;
use crate::*;
use std::sync::mpsc;

#[derive(Clone)]
pub enum LuaCommand {
    ChatMessage(u32, String),
    ChatMessageBroadcast(String),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    SendLua(u32, String),
    SendVehicleLua(u32, String),
    Kick(u32, String),
    SpawnVehicle(VehicleData, Option<u32>),
}

struct LuaTransform(Transform);
struct LuaVehicleData(VehicleData);

impl rlua::UserData for LuaTransform {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getPosition", |_, this, _: ()| {
            Ok(vec![
                this.0.position[0],
                this.0.position[1],
                this.0.position[2],
            ])
        });
        methods.add_method("getRotation", |_, this, _: ()| {
            Ok(vec![
                this.0.rotation[0],
                this.0.rotation[1],
                this.0.rotation[2],
                this.0.rotation[3],
            ])
        });
        methods.add_method("getVelocity", |_, this, _: ()| {
            Ok(vec![
                this.0.velocity[0],
                this.0.velocity[1],
                this.0.velocity[2],
            ])
        });
        methods.add_method("getAngularVelocity", |_, this, _: ()| {
            Ok(vec![
                this.0.angular_velocity[0],
                this.0.angular_velocity[1],
                this.0.angular_velocity[2],
            ])
        });
    }
}
impl rlua::UserData for LuaVehicleData {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getInGameID", |_, this, _: ()| Ok(this.0.in_game_id));
        methods.add_method("getID", |_, this, _: ()| Ok(this.0.server_id));
        methods.add_method("getColor", |_, this, _: ()| Ok(this.0.color.to_vec()));
        methods.add_method("getPalete0", |_, this, _: ()| Ok(this.0.palete_0.to_vec()));
        methods.add_method("getPalete1", |_, this, _: ()| Ok(this.0.palete_1.to_vec()));
        methods.add_method("getPlate", |_, this, _: ()| Ok(this.0.plate.clone()));
        methods.add_method("getName", |_, this, _: ()| Ok(this.0.name.clone()));
        methods.add_method("getOwner", |_, this, _: ()| Ok(this.0.owner));
        methods.add_method("getPartsConfig", |_, this, _: ()| {
            Ok(this.0.parts_config.clone())
        });
    }
}

impl rlua::UserData for Vehicle {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getTransform", |_, this, _: ()| {
            if let Some(transform) = &this.transform {
                Ok(Some(LuaTransform(transform.clone())))
            } else {
                Ok(None)
            }
        });
        methods.add_method("getData", |_, this, _: ()| {
            Ok(LuaVehicleData(this.data.clone()))
        });
        methods.add_method("remove", |lua_ctx, this, _: ()| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender
                .0
                .send(LuaCommand::RemoveVehicle(this.data.server_id))
                .unwrap();
            Ok(())
        });
        methods.add_method("reset", |lua_ctx, this, _: ()| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender
                .0
                .send(LuaCommand::ResetVehicle(this.data.server_id))
                .unwrap();
            Ok(())
        });
        methods.add_method(
            "setPosition",
            |lua_ctx, this, (x, y, z): (f32, f32, f32)| {
                let globals = lua_ctx.globals();
                let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
                sender
                    .0
                    .send(LuaCommand::SendLua(
                        this.data.owner.unwrap_or(0),
                        format!(
                            "be:getObjectByID({}):setPositionNoPhysicsReset(Point3F({}, {}, {}))",
                            this.data.in_game_id, x, y, z
                        ),
                    ))
                    .unwrap();
                Ok(())
            },
        );
        methods.add_method(
            "setPositionRotation",
            |lua_ctx, this, (x, y, z, xr, yr, zr, w): (f32, f32, f32, f32, f32, f32, f32)| {
                let globals = lua_ctx.globals();
                let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
                sender
                    .0
                    .send(LuaCommand::SendLua(
                        this.data.owner.unwrap_or(0),
                        format!(
                            "be:getObjectByID({}):setPosRot({}, {}, {}, {}, {}, {}, {})",
                            this.data.in_game_id, x, y, z, xr, yr, zr, w
                        ),
                    ))
                    .unwrap();
                Ok(())
            },
        );
        methods.add_method("sendLua", |lua_ctx, this, lua: String| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender
                .0
                .send(LuaCommand::SendVehicleLua(this.data.server_id, lua))
                .unwrap();
            Ok(())
        });
    }
}

struct LuaConnection {
    id: u32,
    name: String,
    current_vehicle: u32,
    ip: String,
    secret: String,
}

impl rlua::UserData for LuaConnection {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getIpAddr", |_, this, _: ()| Ok(this.ip.clone()));
        methods.add_method("getSecret", |_, this, _: ()| Ok(this.secret.clone()));
        methods.add_method("getID", |_, this, _: ()| Ok(this.id));
        methods.add_method("getCurrentVehicle", |_, this, _: ()| {
            Ok(this.current_vehicle)
        });
        methods.add_method("getName", |_, this, _: ()| Ok(this.name.clone()));
        methods.add_method("sendChatMessage", |lua_ctx, this, message: String| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender
                .0
                .send(LuaCommand::ChatMessage(this.id, message))
                .unwrap();
            Ok(())
        });
        methods.add_method("kick", |lua_ctx, this, reason: String| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender.0.send(LuaCommand::Kick(this.id, reason)).unwrap();
            Ok(())
        });
        methods.add_method("sendLua", |lua_ctx, this, lua: String| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender.0.send(LuaCommand::SendLua(this.id, lua)).unwrap();
            Ok(())
        });
    }
}

struct Vehicles(HashMap<u32, Vehicle>);

impl<'lua> rlua::ToLua<'lua> for Vehicles {
    fn to_lua(self, lua_ctx: rlua::Context<'lua>) -> rlua::Result<rlua::Value> {
        let t = lua_ctx.create_table()?;
        for (id, vehicle) in self.0 {
            t.set(id, vehicle)?;
        }
        Ok(rlua::Value::Table(t))
    }
}

struct Connections(HashMap<u32, LuaConnection>);

impl<'lua> rlua::ToLua<'lua> for Connections {
    fn to_lua(self, lua_ctx: rlua::Context<'lua>) -> rlua::Result<rlua::Value> {
        let t = lua_ctx.create_table()?;
        for (id, connection) in self.0 {
            t.set(id, connection)?;
        }
        Ok(rlua::Value::Table(t))
    }
}

impl Server {
    pub fn update_lua_vehicles(&self) -> rlua::Result<()> {
        let vehicles = Vehicles(self.vehicles.clone());
        self.lua.context(|lua_ctx| {
            let globals = lua_ctx.globals();
            globals.set("vehicles", vehicles)?;
            Ok(())
        })?;
        Ok(())
    }
    pub fn update_lua_connections(&self) -> rlua::Result<()> {
        let mut connections = Connections(HashMap::new());
        for (id, connection) in &self.connections {
            connections.0.insert(
                *id,
                LuaConnection {
                    id: *id,
                    current_vehicle: connection.client_info_public.current_vehicle,
                    name: connection.client_info_public.name.clone(),
                    ip: connection.conn.remote_address().ip().to_string(),
                    secret: connection.client_info_private.secret.clone(),
                },
            );
        }
        self.lua.context(|lua_ctx| {
            let globals = lua_ctx.globals();
            globals.set("connections", connections)?;
            Ok(())
        })?;
        Ok(())
    }
    pub async fn lua_tick(&mut self) -> rlua::Result<()> {
        let _ = self.update_lua_vehicles();

        self.lua.context(|lua_ctx| {
            let globals = lua_ctx.globals();
            globals.set("SERVER_TICKRATE", self.tickrate)?;
            globals.set("SERVER_NAME", self.name.clone())?;
            globals.set("MAX_PLAYERS", self.max_players)?;
            globals.set("MAX_VEHICLES_PER_CLIENT", self.max_vehicles_per_client)?;
            Ok(())
        })?;

        for command in self.lua_commands.try_iter().collect::<Vec<LuaCommand>>() {
            use LuaCommand::*;
            match command {
                ChatMessage(id, message) => {
                    if let Some(conn) = self.connections.get_mut(&id) {
                        conn.send_chat_message(message.clone()).await;
                    }
                }
                ChatMessageBroadcast(message) => {
                    for (_, client) in &mut self.connections {
                        client.send_chat_message(message.clone()).await;
                    }
                }
                RemoveVehicle(id) => {
                    self.remove_vehicle(id, None).await;
                }
                ResetVehicle(id) => self.reset_vehicle(id, None).await,
                SendLua(id, lua) => {
                    if let Some(conn) = self.connections.get_mut(&id) {
                        conn.send_lua(lua.clone()).await;
                    }
                }
                SendVehicleLua(id, lua) => {
                    for (_, client) in &mut self.connections {
                        let _ = client
                            .ordered
                            .send(ServerCommand::VehicleLuaCommand(id, lua.clone()))
                            .await;
                    }
                }
                Kick(id, reason) => {
                    if let Some(conn) = self.connections.get_mut(&id) {
                        conn.conn.close(1u32.into(), &reason.into_bytes())
                    }
                }
                SpawnVehicle(data, owner) => {
                    let _ = self.spawn_vehicle(owner, data);
                }
            }
        }
        self.lua.context(|lua_ctx| {
            let _ = run_hook::<(), ()>(lua_ctx, String::from("Tick"), ());
        });
        for event in self.lua_watcher_rx.try_recv() {
            use notify::DebouncedEvent::*;
            match event {
                Write(path) => {
                    info!("Lua file {} has been changed. Reloading...", path.display());
                    self.load_lua_addon(&path);
                }
                _ => {}
            }
        }
        Ok(())
    }

    pub fn load_lua_addon(&mut self, path: &std::path::Path) {
        use notify::Watcher;
        use std::io::Read;
        let mut file = std::fs::File::open(path).unwrap();
        let mut buf = String::new();
        file.read_to_string(&mut buf).unwrap();
        self.lua.context(|lua_ctx| {
            if let Err(x) = lua_ctx.load(&buf).eval::<()>() {
                error!("Lua error: {:?}", x);
            }
        });
        self.lua_watcher
            .watch(path, notify::RecursiveMode::NonRecursive)
            .unwrap();
    }

    pub fn load_lua_addons(&mut self) {
        let path = std::path::Path::new("./addons/");
        if !path.exists() {
            std::fs::create_dir(path).unwrap();
        }
        let paths = std::fs::read_dir(path).unwrap();
        for path in paths {
            let path = path.unwrap().path();
            if !path.is_dir() {
                continue;
            }
            let path = path.join("main.lua");
            self.load_lua_addon(&path);
        }
    }
}

#[derive(Clone)]
pub struct MpscChannelSender(mpsc::Sender<LuaCommand>);

impl rlua::UserData for MpscChannelSender {}

pub fn setup_lua() -> (rlua::Lua, mpsc::Receiver<LuaCommand>) {
    let lua = rlua::Lua::new();
    let (tx, rx) = mpsc::channel();
    lua.context(|lua_ctx| {
        let globals = lua_ctx.globals();
        let hooks_table = lua_ctx.create_table().unwrap();
        hooks_table
            .set(
                "register",
                lua_ctx
                    .create_function(
                        |lua_ctx, (hook, name, function): (String, String, rlua::Function)| {
                            let globals = lua_ctx.globals();
                            let hooks_table: rlua::Table = globals.get("hooks").unwrap();
                            if !hooks_table.contains_key(hook.clone()).unwrap() {
                                hooks_table
                                    .set(hook.clone(), Vec::new() as Vec<rlua::Function>)
                                    .unwrap();
                            }
                            let hooks: rlua::Table = hooks_table.get(hook.clone()).unwrap();
                            hooks.set(name, function).unwrap();
                            Ok(())
                        },
                    )
                    .unwrap(),
            )
            .unwrap();
        globals.set("hooks", hooks_table).unwrap();

        let tx_clone = tx.clone();
        globals
            .set("MPSC_CHANNEL_SENDER", MpscChannelSender(tx_clone))
            .unwrap();

        let tx_clone = tx.clone();
        let send_message_broadcast = lua_ctx
            .create_function(move |_, message: String| {
                tx_clone
                    .send(LuaCommand::ChatMessageBroadcast(message))
                    .unwrap();
                Ok(())
            })
            .unwrap();
        globals
            .set("send_message_broadcast", send_message_broadcast)
            .unwrap();
        // FIXME: Bring it back
        /*let tx_clone = tx.clone();
        let spawn_vehicle = lua_ctx
            .create_function(
                move |_, (vehicle_data, owner): (LuaVehicleData, Option<u32>)| {
                    tx_clone
                        .send(LuaCommand::SpawnVehicle(vehicle_data.0, owner))
                        .unwrap();
                    Ok(())
                },
            )
            .unwrap();
        globals.set("spawn_vehicle", spawn_vehicle).unwrap();
        */
        let build_vehicle = lua_ctx
            .create_function(
                move |_,
                      (parts_config, color, p0, p1, plate, name, position, rotation): (
                    String,
                    Vec<f32>,
                    Vec<f32>,
                    Vec<f32>,
                    String,
                    String,
                    Vec<f32>,
                    Vec<f32>,
                )| {
                    Ok(LuaVehicleData(VehicleData {
                        parts_config,
                        in_game_id: 0,
                        color: [color[0], color[1], color[2], color[3], color[4], color[5], color[6], color[7]],
                        palete_0: [p0[0], p0[1], p0[2], p0[3], p0[4], p0[5], p0[6], p0[7]],
                        palete_1: [p1[0], p1[1], p1[2], p1[3], p1[4], p1[5], p1[6], p1[7]],
                        plate: Some(plate),
                        name,
                        server_id: 0,
                        owner: None,
                        position: [position[0], position[1], position[2]],
                        rotation: [rotation[0], rotation[1], rotation[2], rotation[3]],
                    }))
                },
            )
            .unwrap();
        globals.set("build_vehicle", build_vehicle).unwrap();

        let decode_json = lua_ctx
            .create_function(move |lua_ctx, json: String| {
                let decoded = serde_json::from_str::<serde_json::Value>(&json);
                if let Ok(decoded) = decoded {
                    let result = json_to_lua(lua_ctx, decoded);
                    Ok(result)
                } else {
                    Ok(rlua::Value::Nil)
                }
            })
            .unwrap();
        globals.set("decode_json", decode_json).unwrap();

        let encode_json = lua_ctx
            .create_function(move |_lua_ctx, table: rlua::Value| Ok(lua_to_json(table).to_string()))
            .unwrap();
        globals.set("encode_json", encode_json).unwrap();

        let encode_json_pretty = lua_ctx
            .create_function(move |_lua_ctx, table: rlua::Value| {
                Ok(serde_json::to_string_pretty(&lua_to_json(table)).unwrap())
            })
            .unwrap();
        globals
            .set("encode_json_pretty", encode_json_pretty)
            .unwrap();
    });
    (lua, rx)
}

pub fn json_to_lua<'lua>(
    lua_context: rlua::prelude::LuaContext<'lua>,
    value: serde_json::Value,
) -> rlua::Value<'lua> {
    use rlua::ToLua;
    use serde_json::Value::*;
    match value {
        Null => rlua::Value::Nil,
        Bool(x) => rlua::Value::Boolean(x),
        Number(x) => rlua::Value::Number(x.as_f64().unwrap_or(x.as_u64().unwrap_or(0) as f64)),
        String(x) => x.to_lua(lua_context).unwrap(),
        Array(x) => {
            let table = lua_context.create_table().unwrap();
            let mut i = 1;
            for v in x {
                table.set(i, json_to_lua(lua_context, v)).unwrap();
                i += 1;
            }
            rlua::Value::Table(table)
        }
        Object(x) => {
            let table = lua_context.create_table().unwrap();
            for (k, v) in x {
                table.set(k, json_to_lua(lua_context, v)).unwrap();
            }
            rlua::Value::Table(table)
        }
    }
}

pub fn lua_to_json<'lua>(value: rlua::Value) -> serde_json::Value {
    use rlua::Value::*;
    match value {
        Nil => serde_json::Value::Null,
        Boolean(x) => serde_json::Value::Bool(x),
        Integer(x) => serde_json::Value::Number(serde_json::Number::from_f64(x as f64).unwrap()),
        Number(x) => serde_json::Value::Number(serde_json::Number::from_f64(x).unwrap()),
        String(x) => serde_json::Value::String(x.to_str().unwrap().to_string()),
        Table(x) => {
            let mut is_object = false;
            let mut prev = 0;
            for x in x.clone().pairs() {
                let (k, _): (rlua::Value, rlua::Value) = x.unwrap();
                match k {
                    Number(x) => {
                        if x as i64 > (prev + 1) {
                            is_object = true;
                        }
                        prev = x as i64;
                    }
                    Integer(x) => {
                        if x > (prev + 1) {
                            is_object = true;
                        }
                        prev = x;
                    }
                    _ => {
                        is_object = true;
                    }
                }
            }
            if is_object {
                let mut map = serde_json::map::Map::new();
                for x in x.pairs() {
                    let (k, v) = x.unwrap();
                    map.insert(k, lua_to_json(v));
                }
                serde_json::Value::Object(map)
            } else {
                let mut array = vec![];
                for x in x.pairs() {
                    let (_k, v): (rlua::Value, rlua::Value) = x.unwrap();
                    array.push(lua_to_json(v));
                }
                serde_json::Value::Array(array)
            }
        }
        _ => serde_json::Value::Null,
    }
}

pub fn run_hook<
    'lua,
    A: std::clone::Clone + rlua::ToLuaMulti<'lua>,
    R: rlua::FromLuaMulti<'lua>,
>(
    lua_ctx: rlua::Context<'lua>,
    name: String,
    args: A,
) -> Vec<R> {
    let globals = lua_ctx.globals();
    let hooks_table: rlua::Table = globals.get("hooks").unwrap();
    let hooks = hooks_table.get(name);
    let mut result = vec![];
    if let Ok::<rlua::Table, _>(hooks) = hooks {
        for pair in hooks.pairs() {
            let (_, function): (String, rlua::Function) = pair.unwrap();
            match function.call::<A, R>(args.clone()) {
                Ok(r) => result.push(r),
                Err(r) => error!("{}", r),
            }
        }
    }
    result
}
