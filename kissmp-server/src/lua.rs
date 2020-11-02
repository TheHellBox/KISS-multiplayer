/*
Lua is not really designed to be used with rust. And async stuff only makes things worse
This API is probably the best I can do without using unsafe.
*/

use crate::*;
use std::sync::mpsc;

#[derive(Clone)]
pub enum LuaCommand {
    ChatMessage(u32, String),
    ChatMessageBroadcast(String),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    SendLua(u32, String),
    Kick(u32, String),
}

impl rlua::UserData for Transform {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getPosition", |_, this, _: ()|
            Ok(vec![this.position[0], this.position[1], this.position[2]])
        );
        methods.add_method("getRotation", |_, this, _: ()|
            Ok(vec![
                this.rotation[0],
                this.rotation[1],
                this.rotation[2],
                this.rotation[3],
            ])
        );
        methods.add_method("getVelocity", |_, this, _: ()| {
            Ok(vec![this.velocity[0], this.velocity[1], this.velocity[2]])
        });
        methods.add_method("getAngularVelocity", |_, this, _: ()|
            Ok(vec![
                this.angular_velocity[0],
                this.angular_velocity[1],
                this.angular_velocity[2],
            ])
        );
    }
}
impl rlua::UserData for VehicleData {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getInGameID", |_, this, _: ()| Ok(this.in_game_id));
        methods.add_method("getID", |_, this, _: ()| Ok(this.server_id));
        methods.add_method("getColor", |_, this, _: ()| Ok(this.color.to_vec()));
        methods.add_method("getPalete0", |_, this, _: ()| Ok(this.palete_0.to_vec()));
        methods.add_method("getPalete1", |_, this, _: ()| Ok(this.palete_1.to_vec()));
        methods.add_method("getPlate", |_, this, _: ()| Ok(this.plate.clone()));
        methods.add_method("getName", |_, this, _: ()| Ok(this.name.clone()));
        methods.add_method("getOwner", |_, this, _: ()| Ok(this.owner));
        methods.add_method("getPartsConfig", |_, this, _: ()| Ok(this.name.clone()));
    }
}

impl rlua::UserData for Vehicle {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getTransform", |_, this, _: ()| Ok(this.transform.clone()));
        methods.add_method("getData", |_, this, _: ()| Ok(this.data.clone()));
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
    }
}

struct LuaConnection {
    id: u32,
    name: String,
    current_vehicle: u32,
}

impl rlua::UserData for LuaConnection {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("getID", |_, this, _: ()| Ok(this.id));
        methods.add_method("getCurrentVehicle", |_, this, _: ()| Ok(this.current_vehicle));
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
                    current_vehicle: connection.client_info.current_vehicle,
                    name: connection.client_info.name.clone()
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
        let _ = self.update_lua_connections();
        let _ = self.update_lua_vehicles();
        for command in self.lua_commands.try_iter().collect::<Vec<LuaCommand>>() {
            use LuaCommand::*;
            match command {
                ChatMessage(id, message) => {
                    self.connections
                        .get_mut(&id)
                        .unwrap()
                        .send_chat_message(message)
                        .await;
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
                    self.connections.get_mut(&id).unwrap().send_lua(lua).await;
                }
                Kick(id, reason) => self
                    .connections
                    .get_mut(&id)
                    .unwrap()
                    .conn
                    .close(1u32.into(), &reason.into_bytes()),
            }
        }
        self.lua.context(|lua_ctx| {
            let _ = run_hook::<(), ()>(lua_ctx, String::from("Tick"), ());
        });
        for event in self.lua_watcher_rx.try_recv() {
            use notify::DebouncedEvent::*;
            match event {
                Write(path) => {
                    println!("Lua file {} has been changed. Reloading...", path.display());
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
            lua_ctx.load(&buf).eval::<()>().unwrap();
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
    });
    (lua, rx)
}

pub fn run_hook<
    'lua,
    A: std::clone::Clone + rlua::ToLuaMulti<'lua>,
    R: rlua::FromLuaMulti<'lua>,
>(
    lua_ctx: rlua::Context<'lua>,
    name: String,
    args: A,
) -> Option<R> {
    let globals = lua_ctx.globals();
    let hooks_table: rlua::Table = globals.get("hooks").unwrap();
    let hooks = hooks_table.get(name);
    let mut result = None;
    if let Ok::<rlua::Table, _>(hooks) = hooks {
        for pair in hooks.pairs() {
            let (_, function): (String, rlua::Function) = pair.unwrap();
            match function.call::<A, R>(args.clone()) {
                Ok(r) => result = Some(r),
                Err(r) => println!("{}", r),
            }
        }
    }
    result
}
