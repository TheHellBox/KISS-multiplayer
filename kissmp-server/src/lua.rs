use crate::*;
use std::sync::mpsc;

#[derive(Clone)]
pub enum LuaCommand {
    ChatMessage(u32, String),
    ChatMessageBroadcast(String),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    SendLua(u32, String),
}

impl<'lua> rlua::ToLua<'lua> for Transform {
    fn to_lua(self, lua_ctx: rlua::Context<'lua>) -> rlua::Result<rlua::Value> {
        let t = lua_ctx.create_table()?;
        t.set(
            "position",
            vec![self.position[0], self.position[1], self.position[2]],
        )?;
        t.set(
            "rotation",
            vec![
                self.rotation[0],
                self.rotation[1],
                self.rotation[2],
                self.rotation[3],
            ],
        )?;
        t.set(
            "velocity",
            vec![self.velocity[0], self.velocity[1], self.velocity[2]],
        )?;
        t.set(
            "angular_velocity",
            vec![
                self.angular_velocity[0],
                self.angular_velocity[1],
                self.angular_velocity[2],
            ],
        )?;
        Ok(rlua::Value::Table(t))
    }
}

impl<'lua> rlua::ToLua<'lua> for Vehicle {
    fn to_lua(self, lua_ctx: rlua::Context<'lua>) -> rlua::Result<rlua::Value> {
        let owner = self.data.owner.unwrap();
        let id = self.data.server_id.unwrap();
        let t = lua_ctx.create_table()?;
        t.set("transform", self.transform)?;
        t.set(
            "remove",
            lua_ctx.create_function(move |lua_ctx, _: ()| {
                let globals = lua_ctx.globals();
                let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
                sender.0.send(LuaCommand::RemoveVehicle(id)).unwrap();
                Ok(())
            })?,
        )?;
        t.set(
            "reset",
            lua_ctx.create_function(move |lua_ctx, _: ()| {
                let globals = lua_ctx.globals();
                let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
                sender.0.send(LuaCommand::ResetVehicle(id)).unwrap();
                Ok(())
            })?,
        )?;
        t.set(
            "set_position_rotation",
            lua_ctx.create_function(
                move |lua_ctx, (x, y, z, xr, yr, zr, w): (f32, f32, f32, f32, f32, f32, f32)| {
                    let globals = lua_ctx.globals();
                    let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
                    sender
                        .0
                        .send(LuaCommand::SendLua(
                            owner,
                            format!(
                                "be:getObjectByID({}):setPosRot({}, {}, {}, {}, {}, {}, {})",
                                id, x, y, z, xr, yr, zr, w
                            ),
                        ))
                        .unwrap();
                    Ok(())
                },
            )?,
        )?;
        Ok(rlua::Value::Table(t))
    }
}

struct LuaConnection(u32);

impl rlua::UserData for LuaConnection {
    fn add_methods<'lua, M: rlua::UserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("get_id", |_, this, _: ()| Ok(this.0));
        methods.add_method("send_chat_message", |lua_ctx, this, message: String| {
            let globals = lua_ctx.globals();
            let sender: MpscChannelSender = globals.get("MPSC_CHANNEL_SENDER")?;
            sender
                .0
                .send(LuaCommand::ChatMessage(this.0, message))
                .unwrap();
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
    pub async fn run_hook(&mut self, name: String) -> rlua::Result<()> {
        Ok(())
    }
    pub async fn lua_tick(&mut self) -> rlua::Result<()> {
        // Kinda expensive... At least I think so
        let vehicles = Vehicles(self.vehicles.clone());
        let mut connections = Connections(HashMap::new());
        for (id, _) in &self.connections {
            connections.0.insert(*id, LuaConnection(*id));
        }
        self.lua.context(|lua_ctx| {
            let globals = lua_ctx.globals();
            globals.set("vehicles", vehicles)?;
            globals.set("connections", connections)?;
            Ok(())
        })?;
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
                SendLua(id, lua) => {}
            }
        }
        Ok(())
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
        hooks_table.set("register", lua_ctx.create_function(|lua_ctx, (hook, function): (String, rlua::Function)| {
            let globals = lua_ctx.globals();
            let hooks_table: rlua::Table = globals.get("hooks_table").unwrap();
            if let Ok::<rlua::Table, _>(hooks) = hooks_table.get(hook) {

            };
            Ok(())
        }).unwrap()).unwrap();
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

        let tx_clone = tx.clone();
        let send_message_to_client = lua_ctx
            .create_function(move |_, (client_id, message): (u32, String)| {
                tx_clone
                    .send(LuaCommand::ChatMessage(client_id, message))
                    .unwrap();
                Ok(())
            })
            .unwrap();
        globals
            .set("send_message_to_client", send_message_to_client)
            .unwrap();
    });
    (lua, rx)
}
