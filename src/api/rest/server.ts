import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import swaggerJsdoc from 'swagger-jsdoc';
import swaggerUi from 'swagger-ui-express';
import { SolanaFlowSDK } from '../sdk';
import { SDKConfig } from '../sdk/core/types';

// Import route handlers
import assetsRoutes from './routes/assets';
import marketplaceRoutes from './routes/marketplace';
import defiRoutes from './routes/defi';
import bridgeRoutes from './routes/bridge';

/**
 * SolanaFlow REST API Server
 * Provides comprehensive REST endpoints for RWA marketplace operations
 */
export class SolanaFlowAPIServer {
  private app: express.Application;
  private sdk: SolanaFlowSDK;
  private port: number;

  constructor(config: SDKConfig, port: number = 3001) {
    this.app = express();
    this.port = port;
    this.sdk = new SolanaFlowSDK(config);
    
    this.setupMiddleware();
    this.setupSwagger();
    this.setupRoutes();
    this.setupErrorHandling();
  }

  private setupMiddleware(): void {
    // Security middleware
    this.app.use(helmet());
    
    // CORS configuration
    this.app.use(cors({
      origin: process.env.ALLOWED_ORIGINS?.split(',') || ['http://localhost:3000'],
      credentials: true,
    }));

    // Rate limiting
    const limiter = rateLimit({
      windowMs: 15 * 60 * 1000, // 15 minutes
      max: 100, // Limit each IP to 100 requests per windowMs
      message: {
        success: false,
        error: 'Too many requests from this IP, please try again later.',
      },
    });
    this.app.use('/api/', limiter);

    // Body parsing
    this.app.use(express.json({ limit: '10mb' }));
    this.app.use(express.urlencoded({ extended: true }));

    // SDK instance available to all routes
    this.app.set('sdk', this.sdk);

    // Request logging middleware
    this.app.use((req, res, next) => {
      console.log(`${new Date().toISOString()} - ${req.method} ${req.path}`);
      next();
    });
  }

  private setupSwagger(): void {
    const swaggerOptions = {
      definition: {
        openapi: '3.0.0',
        info: {
          title: 'SolanaFlow RWA API',
          version: '1.0.0',
          description: 'Comprehensive REST API for Real-World Asset (RWA) marketplace operations',
          contact: {
            name: 'SolanaFlow Team',
            url: 'https://omniflow.io',
            email: 'api@omniflow.io',
          },
        },
        servers: [
          {
            url: `http://localhost:${this.port}`,
            description: 'Development server',
          },
          {
            url: 'https://api.omniflow.io',
            description: 'Production server',
          },
        ],
        components: {
          schemas: {
            Asset: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                chainId: { type: 'string', enum: ['onechain', 'ethereum', 'polygon', 'bsc'] },
                contractAddress: { type: 'string' },
                tokenId: { type: 'number' },
                type: { type: 'string' },
                name: { type: 'string' },
                description: { type: 'string' },
                value: { type: 'string' },
                currency: { type: 'string' },
                owner: { type: 'string' },
                status: { type: 'string', enum: ['active', 'inactive', 'pending'] },
                createdAt: { type: 'string', format: 'date-time' },
                updatedAt: { type: 'string', format: 'date-time' },
              },
            },
            CreateAssetRequest: {
              type: 'object',
              required: ['chainId', 'type', 'name', 'value', 'owner'],
              properties: {
                chainId: { type: 'string', enum: ['onechain', 'ethereum', 'polygon', 'bsc'] },
                type: { type: 'string' },
                name: { type: 'string' },
                description: { type: 'string' },
                value: { type: 'string' },
                currency: { type: 'string', default: 'USD' },
                owner: { type: 'string' },
                image: { type: 'string' },
                attributes: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      trait_type: { type: 'string' },
                      value: { type: 'string' },
                    },
                  },
                },
              },
            },
            MarketplaceListing: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                assetId: { type: 'string' },
                chainId: { type: 'string' },
                seller: { type: 'string' },
                price: { type: 'string' },
                currency: { type: 'string' },
                listingType: { type: 'string', enum: ['fixed', 'auction'] },
                status: { type: 'string', enum: ['active', 'sold', 'cancelled', 'expired'] },
                createdAt: { type: 'string', format: 'date-time' },
                expiresAt: { type: 'string', format: 'date-time' },
                bids: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      bidder: { type: 'string' },
                      amount: { type: 'string' },
                      timestamp: { type: 'string', format: 'date-time' },
                    },
                  },
                },
              },
            },
            DeFiPosition: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                assetId: { type: 'string' },
                chainId: { type: 'string' },
                protocol: { type: 'string' },
                type: { type: 'string', enum: ['staking', 'lending', 'yield-farming'] },
                amount: { type: 'string' },
                apy: { type: 'string' },
                startDate: { type: 'string', format: 'date-time' },
                status: { type: 'string', enum: ['active', 'completed', 'cancelled'] },
                rewards: {
                  type: 'object',
                  properties: {
                    earned: { type: 'string' },
                    pending: { type: 'string' },
                    claimed: { type: 'string' },
                  },
                },
              },
            },
            BridgeTransfer: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                assetId: { type: 'string' },
                sourceChainId: { type: 'string' },
                targetChainId: { type: 'string' },
                sender: { type: 'string' },
                recipient: { type: 'string' },
                status: { type: 'string', enum: ['pending', 'completed', 'failed', 'cancelled'] },
                lockTransactionHash: { type: 'string' },
                mintTransactionHash: { type: 'string' },
                createdAt: { type: 'string', format: 'date-time' },
                estimatedTime: { type: 'number' },
              },
            },
            Transaction: {
              type: 'object',
              properties: {
                hash: { type: 'string' },
                chainId: { type: 'string' },
                from: { type: 'string' },
                to: { type: 'string' },
                value: { type: 'string' },
                gasPrice: { type: 'string' },
                gasLimit: { type: 'string' },
                status: { type: 'string', enum: ['pending', 'confirmed', 'failed'] },
              },
            },
            Error: {
              type: 'object',
              properties: {
                success: { type: 'boolean', example: false },
                error: { type: 'string' },
                code: { type: 'string' },
                details: { type: 'object' },
              },
            },
          },
          securitySchemes: {
            ApiKeyAuth: {
              type: 'apiKey',
              in: 'header',
              name: 'X-API-Key',
            },
          },
        },
        security: [
          {
            ApiKeyAuth: [],
          },
        ],
      },
      apis: ['./src/api/rest/routes/*.ts'], // Path to the API docs
    };

    const specs = swaggerJsdoc(swaggerOptions);
    this.app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(specs, {
      customCss: '.swagger-ui .topbar { display: none }',
      customSiteTitle: 'SolanaFlow RWA API Documentation',
    }));
  }

  private setupRoutes(): void {
    // Health check endpoint
    this.app.get('/health', (req, res) => {
      res.json({
        success: true,
        status: 'healthy',
        timestamp: new Date().toISOString(),
        version: '1.0.0',
      });
    });

    // API info endpoint
    this.app.get('/api', (req, res) => {
      res.json({
        success: true,
        name: 'SolanaFlow RWA API',
        version: '1.0.0',
        description: 'Comprehensive REST API for Real-World Asset marketplace operations',
        documentation: '/api/docs',
        endpoints: {
          assets: '/api/assets',
          marketplace: '/api/marketplace',
          defi: '/api/defi',
          bridge: '/api/bridge',
        },
      });
    });

    // Mount route handlers
    this.app.use('/api/assets', assetsRoutes);
    this.app.use('/api/marketplace', marketplaceRoutes);
    this.app.use('/api/defi', defiRoutes);
    this.app.use('/api/bridge', bridgeRoutes);

    // Demo endpoints for demo presentations
    this.app.get('/api/demo/load-data', async (req, res) => {
      try {
        const [assets, listings, transfers] = await Promise.all([
          this.sdk.assets.loadDemoAssets(),
          this.sdk.marketplace.loadDemoListings(),
          this.sdk.bridge.loadDemoBridgeTransfers(),
        ]);

        res.json({
          success: true,
          message: 'Demo data loaded successfully',
          data: {
            assets: assets.length,
            listings: listings.length,
            transfers: transfers.length,
          },
        });
      } catch (error) {
        res.status(500).json({
          success: false,
          error: error instanceof Error ? error.message : 'Failed to load demo data',
        });
      }
    });

    // OneChain demo endpoint
    this.app.get('/api/demo/onechain', async (req, res) => {
      try {
        const oneChainProvider = this.sdk.getProvider('onechain');
        if ('simulateDemoDemo' in oneChainProvider) {
          const demoResults = await (oneChainProvider as any).simulateDemoDemo();
          
          res.json({
            success: true,
            message: 'OneChain demo demo simulation completed',
            data: demoResults,
          });
        } else {
          res.json({
            success: true,
            message: 'OneChain provider available',
            data: { chainId: 'onechain', status: 'ready' },
          });
        }
      } catch (error) {
        res.status(500).json({
          success: false,
          error: error instanceof Error ? error.message : 'Demo simulation failed',
        });
      }
    });

    // 404 handler for API routes
    this.app.use('/api/*', (req, res) => {
      res.status(404).json({
        success: false,
        error: 'API endpoint not found',
        path: req.path,
      });
    });
  }

  private setupErrorHandling(): void {
    // Global error handler
    this.app.use((err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
      console.error('API Error:', err);

      // Handle specific error types
      if (err.name === 'ValidationError') {
        return res.status(400).json({
          success: false,
          error: 'Validation error',
          details: err.details,
        });
      }

      if (err.name === 'UnauthorizedError') {
        return res.status(401).json({
          success: false,
          error: 'Unauthorized',
        });
      }

      // Generic error response
      res.status(500).json({
        success: false,
        error: 'Internal server error',
        message: process.env.NODE_ENV === 'development' ? err.message : 'Something went wrong',
      });
    });
  }

  /**
   * Initialize SDK and start the server
   */
  async start(): Promise<void> {
    try {
      // Initialize SDK
      await this.sdk.initialize();
      console.log('SolanaFlow SDK initialized successfully');

      // Start server
      this.app.listen(this.port, () => {
        console.log(`🚀 SolanaFlow API Server running on port ${this.port}`);
        console.log(`📚 API Documentation: http://localhost:${this.port}/api/docs`);
        console.log(`🔍 Health Check: http://localhost:${this.port}/health`);
        console.log(`🎯 OneChain Demo: http://localhost:${this.port}/api/demo/onechain`);
      });
    } catch (error) {
      console.error('Failed to start SolanaFlow API Server:', error);
      process.exit(1);
    }
  }

  /**
   * Graceful shutdown
   */
  async stop(): Promise<void> {
    try {
      await this.sdk.disconnect();
      console.log('SolanaFlow API Server stopped gracefully');
    } catch (error) {
      console.error('Error during shutdown:', error);
    }
  }

  /**
   * Get Express app instance
   */
  getApp(): express.Application {
    return this.app;
  }

  /**
   * Get SDK instance
   */
  getSDK(): SolanaFlowSDK {
    return this.sdk;
  }
}

// Export factory function for easy server creation
export function createSolanaFlowAPIServer(config: SDKConfig, port?: number): SolanaFlowAPIServer {
  return new SolanaFlowAPIServer(config, port);
}

// CLI entry point
if (require.main === module) {
  const config: SDKConfig = {
    chains: ['onechain', 'ethereum', 'polygon', 'bsc'],
    preferredChain: 'onechain',
    environment: process.env.NODE_ENV === 'production' ? 'mainnet' : 'testnet',
    apiEndpoints: {
      rest: process.env.API_BASE_URL || 'http://localhost:3001',
      websocket: process.env.WS_BASE_URL || 'ws://localhost:3001',
    },
    rpcEndpoints: {
      onechain: process.env.ONECHAIN_RPC_URL,
      ethereum: process.env.ETHEREUM_RPC_URL,
      polygon: process.env.POLYGON_RPC_URL,
      bsc: process.env.BSC_RPC_URL,
    },
    apiKeys: {
      infura: process.env.INFURA_API_KEY,
      alchemy: process.env.ALCHEMY_API_KEY,
    },
    privateKey: process.env.PRIVATE_KEY,
  };

  const server = createSolanaFlowAPIServer(config, parseInt(process.env.PORT || '3001'));
  
  // Handle graceful shutdown
  process.on('SIGINT', async () => {
    console.log('\nReceived SIGINT, shutting down gracefully...');
    await server.stop();
    process.exit(0);
  });

  process.on('SIGTERM', async () => {
    console.log('\nReceived SIGTERM, shutting down gracefully...');
    await server.stop();
    process.exit(0);
  });

  // Start the server
  server.start().catch(console.error);
}
