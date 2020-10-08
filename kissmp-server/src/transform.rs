#[derive(Debug, Clone)]
pub struct Transform {
    position: [f32; 3],
    rotation: [f32; 4],
    generation: u32,
}

impl Transform {
    pub fn from_bytes(data: &[u8]) -> (u32, Self) {
        let result: [f32; 9] = bincode::deserialize(&data).unwrap();
        (
            result[0] as u32,
            Self {
                position: [result[1], result[2], result[3]],
                rotation: [result[4], result[5], result[6], result[7]],
                generation: result[8] as u32,
            },
        )
    }
    pub fn to_bytes(&self, vehicle_id: u32) -> Vec<u8> {
        let data = [
            self.position[0],
            self.position[1],
            self.position[2],
            self.rotation[0],
            self.rotation[1],
            self.rotation[2],
            self.rotation[3],
            vehicle_id as f32,
            self.generation as f32,
        ];
        let data = bincode::serialize(&data).unwrap();
        data
    }
}
