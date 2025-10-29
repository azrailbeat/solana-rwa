import { EventEmitter } from 'events';
import { ethers } from 'ethers';

export interface AnalyticsData {
  id: string;
  timestamp: number;
  type: 'asset' | 'marketplace' | 'defi' | 'bridge' | 'user';
  event: string;
  data: any;
  chainId: number;
  userId?: string;
  assetId?: string;
  transactionHash?: string;
}

export interface MetricData {
  name: string;
  value: number;
  timestamp: number;
  tags: Record<string, string>;
}

export interface DashboardMetrics {
  totalVolume: number;
  totalAssets: number;
  totalUsers: number;
  totalTransactions: number;
  averageAssetValue: number;
  topAssetTypes: Array<{ type: string; count: number; volume: number }>;
  chainDistribution: Array<{ chainId: number; volume: number; transactions: number }>;
  timeSeriesData: Array<{ timestamp: number; volume: number; transactions: number }>;
}

export interface UserAnalytics {
  userId: string;
  totalInvestments: number;
  portfolioValue: number;
  riskScore: number;
  preferredAssetTypes: string[];
  transactionHistory: AnalyticsData[];
  performanceMetrics: {
    totalReturn: number;
    sharpeRatio: number;
    volatility: number;
    maxDrawdown: number;
  };
}

export interface AssetAnalytics {
  assetId: string;
  totalVolume: number;
  priceHistory: Array<{ timestamp: number; price: number }>;
  ownershipDistribution: Array<{ address: string; percentage: number }>;
  liquidityMetrics: {
    averageDailyVolume: number;
    bidAskSpread: number;
    marketDepth: number;
  };
  riskMetrics: {
    volatility: number;
    beta: number;
    var: number; // Value at Risk
  };
}

export class AnalyticsManager extends EventEmitter {
  private analyticsData: Map<string, AnalyticsData> = new Map();
  private metrics: Map<string, MetricData[]> = new Map();
  private isInitialized = false;

  constructor() {
    super();
  }

  async initialize(): Promise<void> {
    if (this.isInitialized) return;

    // Initialize analytics storage and connections
    await this.setupAnalyticsStorage();
    await this.loadHistoricalData();
    
    this.isInitialized = true;
    this.emit('initialized');
  }

  private async setupAnalyticsStorage(): Promise<void> {
    // Setup analytics database connections
    // In production, this would connect to analytics databases like ClickHouse, BigQuery, etc.
    console.log('Setting up analytics storage...');
  }

  private async loadHistoricalData(): Promise<void> {
    // Load historical analytics data
    // Generate mock historical data for demo
    const mockData = this.generateMockHistoricalData();
    mockData.forEach(data => {
      this.analyticsData.set(data.id, data);
    });
  }

  async trackEvent(event: Omit<AnalyticsData, 'id' | 'timestamp'>): Promise<string> {
    const analyticsEvent: AnalyticsData = {
      id: `analytics_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      timestamp: Date.now(),
      ...event
    };

    this.analyticsData.set(analyticsEvent.id, analyticsEvent);
    
    // Update metrics
    await this.updateMetrics(analyticsEvent);
    
    this.emit('eventTracked', analyticsEvent);
    return analyticsEvent.id;
  }

  private async updateMetrics(event: AnalyticsData): Promise<void> {
    const metricName = `${event.type}_${event.event}`;
    
    if (!this.metrics.has(metricName)) {
      this.metrics.set(metricName, []);
    }

    const metrics = this.metrics.get(metricName)!;
    metrics.push({
      name: metricName,
      value: 1,
      timestamp: event.timestamp,
      tags: {
        chainId: event.chainId.toString(),
        type: event.type,
        event: event.event
      }
    });

    // Keep only last 1000 metrics per type
    if (metrics.length > 1000) {
      metrics.splice(0, metrics.length - 1000);
    }
  }

  async getDashboardMetrics(timeRange: '1h' | '24h' | '7d' | '30d' = '24h'): Promise<DashboardMetrics> {
    const now = Date.now();
    const timeRangeMs = this.getTimeRangeMs(timeRange);
    const startTime = now - timeRangeMs;

    const relevantData = Array.from(this.analyticsData.values())
      .filter(data => data.timestamp >= startTime);

    // Calculate metrics
    const assetEvents = relevantData.filter(d => d.type === 'asset');
    const marketplaceEvents = relevantData.filter(d => d.type === 'marketplace');
    
    const totalVolume = marketplaceEvents
      .filter(e => e.event === 'purchase')
      .reduce((sum, e) => sum + (e.data?.price || 0), 0);

    const totalAssets = new Set(assetEvents.map(e => e.assetId)).size;
    const totalUsers = new Set(relevantData.map(e => e.userId).filter(Boolean)).size;
    const totalTransactions = relevantData.length;

    // Asset type distribution
    const assetTypeMap = new Map<string, { count: number; volume: number }>();
    assetEvents.forEach(event => {
      const type = event.data?.assetType || 'unknown';
      if (!assetTypeMap.has(type)) {
        assetTypeMap.set(type, { count: 0, volume: 0 });
      }
      const current = assetTypeMap.get(type)!;
      current.count++;
      if (event.event === 'purchase') {
        current.volume += event.data?.price || 0;
      }
    });

    const topAssetTypes = Array.from(assetTypeMap.entries())
      .map(([type, data]) => ({ type, ...data }))
      .sort((a, b) => b.volume - a.volume)
      .slice(0, 5);

    // Chain distribution
    const chainMap = new Map<number, { volume: number; transactions: number }>();
    relevantData.forEach(event => {
      if (!chainMap.has(event.chainId)) {
        chainMap.set(event.chainId, { volume: 0, transactions: 0 });
      }
      const current = chainMap.get(event.chainId)!;
      current.transactions++;
      if (event.event === 'purchase') {
        current.volume += event.data?.price || 0;
      }
    });

    const chainDistribution = Array.from(chainMap.entries())
      .map(([chainId, data]) => ({ chainId, ...data }));

    // Time series data (hourly buckets)
    const timeSeriesData = this.generateTimeSeriesData(relevantData, timeRange);

    return {
      totalVolume,
      totalAssets,
      totalUsers,
      totalTransactions,
      averageAssetValue: totalAssets > 0 ? totalVolume / totalAssets : 0,
      topAssetTypes,
      chainDistribution,
      timeSeriesData
    };
  }

  async getUserAnalytics(userId: string): Promise<UserAnalytics> {
    const userEvents = Array.from(this.analyticsData.values())
      .filter(data => data.userId === userId);

    const investments = userEvents.filter(e => e.event === 'purchase');
    const totalInvestments = investments.reduce((sum, e) => sum + (e.data?.price || 0), 0);

    // Mock portfolio calculations
    const portfolioValue = totalInvestments * (1 + Math.random() * 0.4 - 0.2); // ±20% variation
    const totalReturn = ((portfolioValue - totalInvestments) / totalInvestments) * 100;

    return {
      userId,
      totalInvestments,
      portfolioValue,
      riskScore: Math.random() * 100,
      preferredAssetTypes: ['real_estate', 'carbon_credits'],
      transactionHistory: userEvents.slice(-50), // Last 50 transactions
      performanceMetrics: {
        totalReturn,
        sharpeRatio: Math.random() * 2,
        volatility: Math.random() * 30,
        maxDrawdown: Math.random() * -15
      }
    };
  }

  async getAssetAnalytics(assetId: string): Promise<AssetAnalytics> {
    const assetEvents = Array.from(this.analyticsData.values())
      .filter(data => data.assetId === assetId);

    const purchases = assetEvents.filter(e => e.event === 'purchase');
    const totalVolume = purchases.reduce((sum, e) => sum + (e.data?.price || 0), 0);

    // Generate mock price history
    const priceHistory = this.generateMockPriceHistory();
    
    // Mock ownership distribution
    const ownershipDistribution = [
      { address: '0x1234...5678', percentage: 45 },
      { address: '0x2345...6789', percentage: 30 },
      { address: '0x3456...7890', percentage: 25 }
    ];

    return {
      assetId,
      totalVolume,
      priceHistory,
      ownershipDistribution,
      liquidityMetrics: {
        averageDailyVolume: totalVolume / 30,
        bidAskSpread: Math.random() * 5,
        marketDepth: Math.random() * 100000
      },
      riskMetrics: {
        volatility: Math.random() * 30,
        beta: Math.random() * 2,
        var: Math.random() * -10
      }
    };
  }

  async exportAnalytics(
    format: 'csv' | 'json' | 'xlsx',
    filters?: {
      startDate?: Date;
      endDate?: Date;
      eventTypes?: string[];
      chainIds?: number[];
    }
  ): Promise<string> {
    let data = Array.from(this.analyticsData.values());

    // Apply filters
    if (filters) {
      if (filters.startDate) {
        data = data.filter(d => d.timestamp >= filters.startDate!.getTime());
      }
      if (filters.endDate) {
        data = data.filter(d => d.timestamp <= filters.endDate!.getTime());
      }
      if (filters.eventTypes) {
        data = data.filter(d => filters.eventTypes!.includes(d.event));
      }
      if (filters.chainIds) {
        data = data.filter(d => filters.chainIds!.includes(d.chainId));
      }
    }

    // Export based on format
    switch (format) {
      case 'json':
        return JSON.stringify(data, null, 2);
      case 'csv':
        return this.convertToCSV(data);
      case 'xlsx':
        // In production, use a library like xlsx
        return JSON.stringify(data, null, 2); // Fallback to JSON
      default:
        throw new Error(`Unsupported export format: ${format}`);
    }
  }

  private convertToCSV(data: AnalyticsData[]): string {
    if (data.length === 0) return '';

    const headers = ['id', 'timestamp', 'type', 'event', 'chainId', 'userId', 'assetId', 'transactionHash'];
    const csvRows = [headers.join(',')];

    data.forEach(row => {
      const values = headers.map(header => {
        const value = row[header as keyof AnalyticsData];
        return typeof value === 'string' ? `"${value}"` : value || '';
      });
      csvRows.push(values.join(','));
    });

    return csvRows.join('\n');
  }

  private getTimeRangeMs(timeRange: string): number {
    switch (timeRange) {
      case '1h': return 60 * 60 * 1000;
      case '24h': return 24 * 60 * 60 * 1000;
      case '7d': return 7 * 24 * 60 * 60 * 1000;
      case '30d': return 30 * 24 * 60 * 60 * 1000;
      default: return 24 * 60 * 60 * 1000;
    }
  }

  private generateTimeSeriesData(data: AnalyticsData[], timeRange: string): Array<{ timestamp: number; volume: number; transactions: number }> {
    const bucketSize = timeRange === '1h' ? 5 * 60 * 1000 : // 5 minutes
                      timeRange === '24h' ? 60 * 60 * 1000 : // 1 hour
                      timeRange === '7d' ? 6 * 60 * 60 * 1000 : // 6 hours
                      24 * 60 * 60 * 1000; // 1 day

    const buckets = new Map<number, { volume: number; transactions: number }>();
    
    data.forEach(event => {
      const bucketTime = Math.floor(event.timestamp / bucketSize) * bucketSize;
      if (!buckets.has(bucketTime)) {
        buckets.set(bucketTime, { volume: 0, transactions: 0 });
      }
      const bucket = buckets.get(bucketTime)!;
      bucket.transactions++;
      if (event.event === 'purchase') {
        bucket.volume += event.data?.price || 0;
      }
    });

    return Array.from(buckets.entries())
      .map(([timestamp, data]) => ({ timestamp, ...data }))
      .sort((a, b) => a.timestamp - b.timestamp);
  }

  private generateMockHistoricalData(): AnalyticsData[] {
    const data: AnalyticsData[] = [];
    const now = Date.now();
    const thirtyDaysAgo = now - (30 * 24 * 60 * 60 * 1000);

    for (let i = 0; i < 1000; i++) {
      const timestamp = thirtyDaysAgo + Math.random() * (now - thirtyDaysAgo);
      const eventTypes = ['asset_created', 'asset_purchased', 'listing_created', 'bid_placed'];
      const event = eventTypes[Math.floor(Math.random() * eventTypes.length)];

      data.push({
        id: `mock_${i}`,
        timestamp,
        type: 'marketplace',
        event,
        chainId: [1, 137, 56, 1001][Math.floor(Math.random() * 4)],
        userId: `user_${Math.floor(Math.random() * 100)}`,
        assetId: `asset_${Math.floor(Math.random() * 50)}`,
        data: {
          price: Math.random() * 100000,
          assetType: ['real_estate', 'carbon_credits', 'precious_metals'][Math.floor(Math.random() * 3)]
        }
      });
    }

    return data;
  }

  private generateMockPriceHistory(): Array<{ timestamp: number; price: number }> {
    const history: Array<{ timestamp: number; price: number }> = [];
    const now = Date.now();
    let price = 50000 + Math.random() * 50000; // Starting price

    for (let i = 30; i >= 0; i--) {
      const timestamp = now - (i * 24 * 60 * 60 * 1000);
      price *= (1 + (Math.random() - 0.5) * 0.1); // ±5% daily variation
      history.push({ timestamp, price });
    }

    return history;
  }

  // Demo methods for demo presentation
  async loadDemoAnalytics(): Promise<void> {
    console.log('Loading demo analytics data...');
    
    // Generate comprehensive demo data
    const demoEvents = [
      {
        type: 'asset' as const,
        event: 'created',
        chainId: 1001,
        userId: 'demo_user_1',
        assetId: 'demo_asset_1',
        data: { assetType: 'real_estate', value: 250000 }
      },
      {
        type: 'marketplace' as const,
        event: 'listed',
        chainId: 1001,
        userId: 'demo_user_1',
        assetId: 'demo_asset_1',
        data: { price: 250000 }
      },
      {
        type: 'marketplace' as const,
        event: 'purchase',
        chainId: 1001,
        userId: 'demo_user_2',
        assetId: 'demo_asset_1',
        data: { price: 250000 }
      }
    ];

    for (const event of demoEvents) {
      await this.trackEvent(event);
    }

    this.emit('demoAnalyticsLoaded');
  }

  async generateDemoReport(): Promise<string> {
    const metrics = await this.getDashboardMetrics('24h');
    
    return `
# OmniFlow Analytics Demo Report

## Key Metrics (Last 24h)
- Total Volume: $${metrics.totalVolume.toLocaleString()}
- Total Assets: ${metrics.totalAssets}
- Total Users: ${metrics.totalUsers}
- Total Transactions: ${metrics.totalTransactions}

## Top Asset Types
${metrics.topAssetTypes.map(type => 
  `- ${type.type}: ${type.count} assets, $${type.volume.toLocaleString()} volume`
).join('\n')}

## Chain Distribution
${metrics.chainDistribution.map(chain => 
  `- Chain ${chain.chainId}: ${chain.transactions} transactions, $${chain.volume.toLocaleString()} volume`
).join('\n')}

Generated at: ${new Date().toISOString()}
    `.trim();
  }
}
