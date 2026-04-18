use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Statistical summary of a measurement series
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatsSummary {
    /// Total number of samples
    pub count: usize,
    /// Minimum value
    pub min: f32,
    /// Maximum value
    pub max: f32,
    /// Mean (average)
    pub mean: f32,
    /// Median (p50)
    pub p50: f32,
    /// 95th percentile
    pub p95: f32,
    /// 99th percentile
    pub p99: f32,
}

impl StatsSummary {
    pub fn new(samples: &[f32]) -> Option<Self> {
        if samples.is_empty() {
            return None;
        }

        let count = samples.len();
        let min = samples.iter().cloned().fold(f32::INFINITY, f32::min);
        let max = samples.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        let mean = samples.iter().sum::<f32>() / count as f32;

        // Sort a copy for percentiles
        let mut sorted = samples.to_vec();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

        let p50 = percentile(&sorted, 50.0);
        let p95 = percentile(&sorted, 95.0);
        let p99 = percentile(&sorted, 99.0);

        Some(Self {
            count,
            min,
            max,
            mean,
            p50,
            p95,
            p99,
        })
    }

    /// Export as a single CSV row
    pub fn to_csv_row(&self, prefix: &str) -> String {
        format!(
            "{prefix}_count,{prefix}_min,{prefix}_max,{prefix}_mean,{prefix}_p50,{prefix}_p95,{prefix}_p99\n\
             {count},{min},{max},{mean},{p50},{p95},{p99}",
            prefix = prefix,
            count = self.count,
            min = self.min,
            max = self.max,
            mean = self.mean,
            p50 = self.p50,
            p95 = self.p95,
            p99 = self.p99
        )
    }

    /// Export as a single CSV row (compact version)
    pub fn to_csv_row_compact(&self, _prefix: &str) -> String {
        format!(
            "{},{},{},{},{},{},{}",
            self.count, self.min, self.max, self.mean, self.p50, self.p95, self.p99
        )
    }

    /// Get header for CSV
    pub fn csv_header(prefix: &str) -> String {
        format!(
            "{prefix}_count,{prefix}_min,{prefix}_max,{prefix}_mean,{prefix}_p50,{prefix}_p95,{prefix}_p99"
        )
    }
}

/// Compute percentile from a sorted slice
/// `p` is the percentile (0-100)
fn percentile(sorted: &[f32], p: f32) -> f32 {
    if sorted.is_empty() {
        return 0.0;
    }

    if sorted.len() == 1 {
        return sorted[0];
    }

    // Use linear interpolation between closest ranks
    let n = sorted.len() as f32;
    let rank = (p / 100.0) * (n - 1.0);
    let lower_idx = rank.floor() as usize;
    let upper_idx = rank.ceil() as usize;
    let fraction = rank - lower_idx as f32;

    if lower_idx == upper_idx {
        sorted[lower_idx]
    } else {
        sorted[lower_idx] * (1.0 - fraction) + sorted[upper_idx] * fraction
    }
}

/// Live divergence statistics for a single vehicle
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DivergenceStats {
    /// Vehicle ID these stats belong to
    pub vehicle_id: u32,
    /// Generation/tick these stats were computed for
    pub generation: u64,
    /// Timestamp of computation
    pub timestamp: f64,
    /// Position divergence stats [m]
    pub position_stats: Option<StatsSummary>,
    /// Orientation divergence stats [rad]
    pub orientation_stats: Option<StatsSummary>,
}

impl DivergenceStats {
    pub fn new(vehicle_id: u32, generation: u64, timestamp: f64) -> Self {
        Self {
            vehicle_id,
            generation,
            timestamp,
            position_stats: None,
            orientation_stats: None,
        }
    }

    /// Compute stats from position and orientation samples
    pub fn compute_from_divergence_samples(
        &mut self,
        samples: &[crate::measurement::PoseDivergenceSample],
    ) {
        let positions: Vec<f32> = samples.iter().map(|s| s.position_magnitude()).collect();
        let orientations: Vec<f32> = samples.iter().map(|s| s.orientation_delta).collect();

        self.position_stats = StatsSummary::new(&positions);
        self.orientation_stats = StatsSummary::new(&orientations);
    }
}

/// Manager for computing and tracking live statistics
#[derive(Debug, Clone)]
pub struct StatsManager {
    /// Last computed stats per vehicle
    pub last_stats: HashMap<u32, DivergenceStats>,
    /// Window size for statistics computation (number of samples)
    pub window_size: usize,
}

impl StatsManager {
    pub fn new(window_size: usize) -> Self {
        Self {
            last_stats: HashMap::new(),
            window_size,
        }
    }

    /// Default window size for live stats (e.g., last 5 seconds at 60 Hz = 300 samples)
    pub fn default_live_window() -> Self {
        Self::new(300)
    }

    /// Compute stats for a vehicle from its divergence buffer
    pub fn compute_for_vehicle(
        &mut self,
        vehicle_id: u32,
        generation: u64,
        timestamp: f64,
        samples: &[crate::measurement::PoseDivergenceSample],
    ) -> DivergenceStats {
        let mut stats = DivergenceStats::new(vehicle_id, generation, timestamp);
        stats.compute_from_divergence_samples(samples);

        self.last_stats.insert(vehicle_id, stats.clone());
        stats
    }

    /// Get last computed stats for a vehicle
    pub fn get_stats(&self, vehicle_id: u32) -> Option<&DivergenceStats> {
        self.last_stats.get(&vehicle_id)
    }

    /// Clear all stats
    pub fn clear(&mut self) {
        self.last_stats.clear();
    }
}

/// Export complete divergence report to CSV
pub fn export_divergence_report_csv(
    _buffers: &std::collections::HashMap<u32, crate::measurement::PoseDivergenceBuffer>,
    stats: &HashMap<u32, DivergenceStats>,
) -> String {
    let mut csv = String::new();

    // Separator
    csv.push_str("# ============================================\n");
    csv.push_str("# POSE DIVERGENCE REPORT\n");
    csv.push_str("# ============================================\n\n");

    // Stats summary section
    csv.push_str("# ============================================\n");
    csv.push_str("# LIVE STATISTICS (per vehicle)\n");
    csv.push_str("# ============================================\n");

    // Header
    let header = format!(
        "vehicle_id,generation,timestamp,pos_count,pos_min,pos_max,pos_mean,pos_p50,pos_p95,pos_p99,orient_count,orient_min,orient_max,orient_mean,orient_p50,orient_p95,orient_p99\n"
    );
    csv.push_str(&header);

    for (_vehicle_id, divergence_stats) in stats {
        let pos = divergence_stats.position_stats.as_ref();
        let orient = divergence_stats.orientation_stats.as_ref();

        let pos_str = pos.map(|s| s.to_csv_row_compact("pos")).unwrap_or_else(|| "NaN,NaN,NaN,NaN,NaN,NaN,NaN".to_string());
        let orient_str = orient.map(|s| s.to_csv_row_compact("orient")).unwrap_or_else(|| "NaN,NaN,NaN,NaN,NaN,NaN,NaN".to_string());

        csv.push_str(&format!(
            "{},{},{},{},{}\n",
            divergence_stats.vehicle_id,
            divergence_stats.generation,
            divergence_stats.timestamp,
            pos_str,
            orient_str
        ));
    }

    csv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_percentile_single_value() {
        let data = [5.0];
        assert_eq!(percentile(&data, 50.0), 5.0);
        assert_eq!(percentile(&data, 95.0), 5.0);
        assert_eq!(percentile(&data, 99.0), 5.0);
    }

    #[test]
    fn test_percentile_uniform() {
        let data = [1.0, 2.0, 3.0, 4.0, 5.0];
        assert_eq!(percentile(&data, 0.0), 1.0);
        assert_eq!(percentile(&data, 50.0), 3.0);
        assert_eq!(percentile(&data, 100.0), 5.0);
    }

    #[test]
    fn test_percentile_interpolation() {
        let data = [1.0, 2.0, 3.0, 4.0, 5.0];
        let p25 = percentile(&data, 25.0);
        // Should be between 1 and 2, closer to 2
        assert!(p25 >= 1.0 && p25 <= 2.0);
    }

    #[test]
    fn test_stats_summary() {
        let data = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0];
        let stats = StatsSummary::new(&data).unwrap();

        assert_eq!(stats.count, 10);
        assert_eq!(stats.min, 1.0);
        assert_eq!(stats.max, 10.0);
        assert_eq!(stats.mean, 5.5);
        // p50 should be around 5.5 (median of 1-10)
        assert!(stats.p50 >= 5.0 && stats.p50 <= 6.0);
    }

    #[test]
    fn test_stats_summary_empty() {
        let data: [f32; 0] = [];
        assert!(StatsSummary::new(&data).is_none());
    }
}
