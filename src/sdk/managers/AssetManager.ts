import { EventEmitter } from 'events';
import { ChainProvider } from '../core/types';
import { 
  Asset, 
  AssetType, 
  AssetMetadata, 
  Transaction, 
  ChainId,
  SDKError,
  AssetFilter,
  CreateAssetRequest
} from '../core/types';

/**
 * Asset Manager - Handles RWA asset creation, management, and cross-chain operations
 */
export class AssetManager extends EventEmitter {
  private providers: Map<ChainId, ChainProvider>;
  private assets: Map<string, Asset> = new Map();

  constructor(providers: Map<ChainId, ChainProvider>) {
    super();
    this.providers = providers;
  }

  /**
   * Create a new RWA asset on specified chain
   */
  async createAsset(request: CreateAssetRequest): Promise<Asset> {
    const provider = this.providers.get(request.chainId);
    if (!provider) {
      throw new SDKError(`Provider not found for chain: ${request.chainId}`, 'CHAIN_ERROR');
    }

    try {
      // Generate unique asset ID
      const assetId = `${request.chainId}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

      // Create metadata
      const metadata: AssetMetadata = {
        name: request.name,
        description: request.description,
        image: request.image,
        attributes: request.attributes || [],
        externalUrl: request.externalUrl,
        animationUrl: request.animationUrl,
      };

      // Create asset object
      const asset: Asset = {
        id: assetId,
        chainId: request.chainId,
        contractAddress: request.contractAddress || '',
        tokenId: request.tokenId || 0,
        type: request.type,
        name: request.name,
        description: request.description,
        value: request.value,
        currency: request.currency || 'USD',
        metadata,
        owner: request.owner,
        compliance: request.compliance || {
          level: 'basic',
          verifications: [],
          region: 'global',
        },
        fractional: request.fractional || {
          enabled: false,
          totalShares: 0,
          availableShares: 0,
          pricePerShare: '0',
        },
        status: 'active',
        createdAt: new Date(),
        updatedAt: new Date(),
      };

      // If OneChain provider, use specialized creation method
      if (request.chainId === 'onechain' && 'createRWAToken' in provider) {
        const tx = await (provider as any).createRWAToken(
          request.name,
          request.symbol || request.name.replace(/\s+/g, '').toUpperCase(),
          JSON.stringify(metadata),
          request.value
        );
        
        asset.transactionHash = tx.hash;
        this.emit('assetCreated', { asset, transaction: tx });
      } else {
        // Generic contract interaction for other chains
        this.emit('assetCreated', { asset });
      }

      // Store asset
      this.assets.set(assetId, asset);

      return asset;
    } catch (error) {
      throw new SDKError(`Failed to create asset: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Get asset by ID
   */
  async getAsset(assetId: string): Promise<Asset | null> {
    const asset = this.assets.get(assetId);
    if (!asset) return null;

    // Refresh asset data from chain if needed
    await this.refreshAssetData(asset);
    return asset;
  }

  /**
   * Get all assets with optional filtering
   */
  async getAssets(filter?: AssetFilter): Promise<Asset[]> {
    let assets = Array.from(this.assets.values());

    if (filter) {
      if (filter.chainId) {
        assets = assets.filter(asset => asset.chainId === filter.chainId);
      }
      if (filter.type) {
        assets = assets.filter(asset => asset.type === filter.type);
      }
      if (filter.owner) {
        assets = assets.filter(asset => asset.owner.toLowerCase() === filter.owner!.toLowerCase());
      }
      if (filter.status) {
        assets = assets.filter(asset => asset.status === filter.status);
      }
      if (filter.minValue) {
        assets = assets.filter(asset => parseFloat(asset.value) >= filter.minValue!);
      }
      if (filter.maxValue) {
        assets = assets.filter(asset => parseFloat(asset.value) <= filter.maxValue!);
      }
    }

    return assets;
  }

  /**
   * Update asset metadata
   */
  async updateAsset(assetId: string, updates: Partial<Asset>): Promise<Asset> {
    const asset = this.assets.get(assetId);
    if (!asset) {
      throw new SDKError(`Asset not found: ${assetId}`, 'ASSET_ERROR');
    }

    const updatedAsset = {
      ...asset,
      ...updates,
      updatedAt: new Date(),
    };

    this.assets.set(assetId, updatedAsset);
    this.emit('assetUpdated', { asset: updatedAsset });

    return updatedAsset;
  }

  /**
   * Transfer asset to new owner
   */
  async transferAsset(assetId: string, toAddress: string): Promise<Transaction> {
    const asset = this.assets.get(assetId);
    if (!asset) {
      throw new SDKError(`Asset not found: ${assetId}`, 'ASSET_ERROR');
    }

    const provider = this.providers.get(asset.chainId);
    if (!provider) {
      throw new SDKError(`Provider not found for chain: ${asset.chainId}`, 'CHAIN_ERROR');
    }

    try {
      // Create transfer transaction
      const tx = await provider.sendTransaction({
        to: asset.contractAddress,
        data: this.encodeTransferData(asset.tokenId, toAddress),
      });

      // Update asset owner
      await this.updateAsset(assetId, { owner: toAddress });

      this.emit('assetTransferred', { asset, toAddress, transaction: tx });
      return tx;
    } catch (error) {
      throw new SDKError(`Failed to transfer asset: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Enable fractional ownership for an asset
   */
  async enableFractionalOwnership(
    assetId: string, 
    totalShares: number, 
    pricePerShare: string
  ): Promise<Asset> {
    const asset = this.assets.get(assetId);
    if (!asset) {
      throw new SDKError(`Asset not found: ${assetId}`, 'ASSET_ERROR');
    }

    const updatedAsset = await this.updateAsset(assetId, {
      fractional: {
        enabled: true,
        totalShares,
        availableShares: totalShares,
        pricePerShare,
      },
    });

    this.emit('fractionalOwnershipEnabled', { asset: updatedAsset });
    return updatedAsset;
  }

  /**
   * Get assets by type
   */
  async getAssetsByType(type: AssetType): Promise<Asset[]> {
    return this.getAssets({ type });
  }

  /**
   * Get assets by owner
   */
  async getAssetsByOwner(owner: string): Promise<Asset[]> {
    return this.getAssets({ owner });
  }

  /**
   * Get assets by chain
   */
  async getAssetsByChain(chainId: ChainId): Promise<Asset[]> {
    return this.getAssets({ chainId });
  }

  /**
   * Search assets by name or description
   */
  async searchAssets(query: string): Promise<Asset[]> {
    const assets = Array.from(this.assets.values());
    const lowerQuery = query.toLowerCase();

    return assets.filter(asset => 
      asset.name.toLowerCase().includes(lowerQuery) ||
      asset.description.toLowerCase().includes(lowerQuery) ||
      asset.metadata.attributes?.some(attr => 
        attr.trait_type.toLowerCase().includes(lowerQuery) ||
        attr.value.toString().toLowerCase().includes(lowerQuery)
      )
    );
  }

  /**
   * Get asset valuation history
   */
  async getAssetValuation(assetId: string): Promise<{
    currentValue: string;
    currency: string;
    lastUpdated: Date;
    history: Array<{ value: string; date: Date }>;
  }> {
    const asset = this.assets.get(assetId);
    if (!asset) {
      throw new SDKError(`Asset not found: ${assetId}`, 'ASSET_ERROR');
    }

    // Mock valuation data for demo
    return {
      currentValue: asset.value,
      currency: asset.currency,
      lastUpdated: asset.updatedAt,
      history: [
        { value: asset.value, date: asset.updatedAt },
        { value: (parseFloat(asset.value) * 0.95).toString(), date: new Date(Date.now() - 86400000) },
        { value: (parseFloat(asset.value) * 0.92).toString(), date: new Date(Date.now() - 172800000) },
      ],
    };
  }

  /**
   * Validate asset compliance
   */
  async validateCompliance(assetId: string): Promise<{
    isCompliant: boolean;
    issues: string[];
    recommendations: string[];
  }> {
    const asset = this.assets.get(assetId);
    if (!asset) {
      throw new SDKError(`Asset not found: ${assetId}`, 'ASSET_ERROR');
    }

    const issues: string[] = [];
    const recommendations: string[] = [];

    // Basic compliance checks
    if (!asset.compliance.verifications.includes('kyc')) {
      issues.push('KYC verification missing');
      recommendations.push('Complete KYC verification process');
    }

    if (!asset.compliance.verifications.includes('aml')) {
      issues.push('AML verification missing');
      recommendations.push('Complete AML compliance check');
    }

    if (asset.compliance.level === 'basic') {
      recommendations.push('Consider upgrading to enhanced compliance level');
    }

    return {
      isCompliant: issues.length === 0,
      issues,
      recommendations,
    };
  }

  /**
   * Private helper methods
   */
  private async refreshAssetData(asset: Asset): Promise<void> {
    // Refresh asset data from blockchain if needed
    const provider = this.providers.get(asset.chainId);
    if (!provider || !asset.contractAddress) return;

    try {
      // Mock refresh logic - in real implementation, query contract state
      asset.updatedAt = new Date();
    } catch (error) {
      console.warn(`Failed to refresh asset data for ${asset.id}:`, error);
    }
  }

  private encodeTransferData(tokenId: number, toAddress: string): string {
    // Mock transfer data encoding - in real implementation, use proper ABI encoding
    return `0x${tokenId.toString(16).padStart(64, '0')}${toAddress.slice(2).padStart(64, '0')}`;
  }

  /**
   * Load demo assets for demo presentations
   */
  async loadDemoAssets(): Promise<Asset[]> {
    const demoAssets: CreateAssetRequest[] = [
      {
        chainId: 'onechain',
        type: 'real-estate',
        name: 'Manhattan Luxury Penthouse',
        description: 'Premium 3-bedroom penthouse in Manhattan with city views',
        value: '2500000',
        currency: 'USD',
        owner: '0x1234567890123456789012345678901234567890',
        image: 'https://example.com/penthouse.jpg',
        attributes: [
          { trait_type: 'Location', value: 'Manhattan, NY' },
          { trait_type: 'Bedrooms', value: 3 },
          { trait_type: 'Square Feet', value: 2500 },
          { trait_type: 'Year Built', value: 2020 },
        ],
        compliance: {
          level: 'enhanced',
          verifications: ['kyc', 'aml', 'accredited'],
          region: 'US',
        },
      },
      {
        chainId: 'onechain',
        type: 'renewable-energy',
        name: 'Texas Solar Farm',
        description: '50MW solar installation generating clean energy',
        value: '5000000',
        currency: 'USD',
        owner: '0x1234567890123456789012345678901234567890',
        image: 'https://example.com/solar-farm.jpg',
        attributes: [
          { trait_type: 'Capacity', value: '50MW' },
          { trait_type: 'Location', value: 'Austin, TX' },
          { trait_type: 'Annual Generation', value: '120GWh' },
          { trait_type: 'CO2 Offset', value: '60000 tons/year' },
        ],
        compliance: {
          level: 'enhanced',
          verifications: ['kyc', 'aml', 'environmental'],
          region: 'US',
        },
      },
      {
        chainId: 'onechain',
        type: 'carbon-credits',
        name: 'Amazon Rainforest Conservation',
        description: 'Verified carbon credits from rainforest preservation',
        value: '750000',
        currency: 'USD',
        owner: '0x1234567890123456789012345678901234567890',
        image: 'https://example.com/rainforest.jpg',
        attributes: [
          { trait_type: 'Credits', value: '10000 tCO2' },
          { trait_type: 'Location', value: 'Amazon, Brazil' },
          { trait_type: 'Verification', value: 'Verra VCS' },
          { trait_type: 'Vintage', value: '2024' },
        ],
        compliance: {
          level: 'enhanced',
          verifications: ['kyc', 'aml', 'environmental'],
          region: 'LATAM',
        },
      },
    ];

    const createdAssets: Asset[] = [];
    for (const assetRequest of demoAssets) {
      try {
        const asset = await this.createAsset(assetRequest);
        createdAssets.push(asset);
      } catch (error) {
        console.warn(`Failed to create demo asset ${assetRequest.name}:`, error);
      }
    }

    return createdAssets;
  }
}
