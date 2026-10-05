export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      api_docs: {
        Row: {
          changelog: string | null
          created_at: string
          id: string
          published_by: string | null
          spec: NonNullable<Json>
          version: string
        }
        Insert: {
          changelog?: string | null
          created_at?: string
          id?: string
          published_by?: string | null
          spec: NonNullable<Json>
          version: string
        }
        Update: {
          changelog?: string | null
          created_at?: string
          id?: string
          published_by?: string | null
          spec?: NonNullable<Json>
          version?: string
        }
        Relationships: []
      }
      api_keys: {
        Row: {
          created_at: string
          created_by: string | null
          expires_at: string | null
          id: string
          key_hash: string
          key_prefix: string
          last_used_at: string | null
          name: string
          scopes: NonNullable<Json>
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          id?: string
          key_hash: string
          key_prefix: string
          last_used_at?: string | null
          name: string
          scopes?: NonNullable<Json>
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          id?: string
          key_hash?: string
          key_prefix?: string
          last_used_at?: string | null
          name?: string
          scopes?: NonNullable<Json>
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      approval_ccs: {
        Row: {
          cc_user_id: string
          created_at: string
          instance_id: string
          read_at: string | null
        }
        Insert: {
          cc_user_id: string
          created_at?: string
          instance_id: string
          read_at?: string | null
        }
        Update: {
          cc_user_id?: string
          created_at?: string
          instance_id?: string
          read_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "approval_ccs_cc_user_id_fkey"
            columns: ["cc_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_ccs_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "approval_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_flows: {
        Row: {
          branches: Json | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          nodes: NonNullable<Json>
          status: string
          template_id: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        Insert: {
          branches?: Json | null
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          nodes: NonNullable<Json>
          status?: string
          template_id: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Update: {
          branches?: Json | null
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          nodes?: NonNullable<Json>
          status?: string
          template_id?: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "approval_flows_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "approval_form_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_form_templates: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          module: string
          name: string
          schema: NonNullable<Json>
          status: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          module: string
          name: string
          schema: NonNullable<Json>
          status?: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          module?: string
          name?: string
          schema?: NonNullable<Json>
          status?: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Relationships: []
      }
      approval_instances: {
        Row: {
          created_at: string
          current_seq: number
          flow_version_id: string
          form_data: NonNullable<Json>
          id: string
          initiator_id: string
          last_urged_at: string | null
          module: string
          ref_id: string | null
          ref_type: string | null
          status: string
          template_version_id: string
          title: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          current_seq?: number
          flow_version_id: string
          form_data: NonNullable<Json>
          id?: string
          initiator_id: string
          last_urged_at?: string | null
          module: string
          ref_id?: string | null
          ref_type?: string | null
          status?: string
          template_version_id: string
          title: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          current_seq?: number
          flow_version_id?: string
          form_data?: NonNullable<Json>
          id?: string
          initiator_id?: string
          last_urged_at?: string | null
          module?: string
          ref_id?: string | null
          ref_type?: string | null
          status?: string
          template_version_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "approval_instances_flow_version_id_fkey"
            columns: ["flow_version_id"]
            isOneToOne: false
            referencedRelation: "approval_flows"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_instances_initiator_id_fkey"
            columns: ["initiator_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_instances_template_version_id_fkey"
            columns: ["template_version_id"]
            isOneToOne: false
            referencedRelation: "approval_form_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_tasks: {
        Row: {
          acted_at: string | null
          assignee_id: string
          comment: string | null
          created_at: string
          id: string
          instance_id: string
          seq: number
          status: string
        }
        Insert: {
          acted_at?: string | null
          assignee_id: string
          comment?: string | null
          created_at?: string
          id?: string
          instance_id: string
          seq: number
          status?: string
        }
        Update: {
          acted_at?: string | null
          assignee_id?: string
          comment?: string | null
          created_at?: string
          id?: string
          instance_id?: string
          seq?: number
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "approval_tasks_assignee_id_fkey"
            columns: ["assignee_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_tasks_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "approval_instances"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_logins: {
        Row: {
          created_at: string
          email: string | null
          fail_reason: string | null
          id: number
          ip: unknown
          success: boolean
          ua: string | null
          user_id: string | null
        }
        Insert: {
          created_at?: string
          email?: string | null
          fail_reason?: string | null
          id?: never
          ip?: unknown
          success: boolean
          ua?: string | null
          user_id?: string | null
        }
        Update: {
          created_at?: string
          email?: string | null
          fail_reason?: string | null
          id?: never
          ip?: unknown
          success?: boolean
          ua?: string | null
          user_id?: string | null
        }
        Relationships: []
      }
      audit_operations: {
        Row: {
          action: string
          actor_id: string | null
          created_at: string
          diff: Json | null
          id: number
          ip: unknown
          module: string
          object_id: string | null
          object_type: string
          ua: string | null
        }
        Insert: {
          action: string
          actor_id?: string | null
          created_at?: string
          diff?: Json | null
          id?: never
          ip?: unknown
          module: string
          object_id?: string | null
          object_type: string
          ua?: string | null
        }
        Update: {
          action?: string
          actor_id?: string | null
          created_at?: string
          diff?: Json | null
          id?: never
          ip?: unknown
          module?: string
          object_id?: string | null
          object_type?: string
          ua?: string | null
        }
        Relationships: []
      }
      audit_row_version_whitelist: {
        Row: {
          created_at: string
          created_by: string | null
          enabled: boolean
          table_name: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          enabled?: boolean
          table_name: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          enabled?: boolean
          table_name?: string
          updated_at?: string
        }
        Relationships: []
      }
      audit_row_versions: {
        Row: {
          changed_at: string
          changed_by: string | null
          data: NonNullable<Json>
          id: number
          record_id: string
          table_name: string
          version: number
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          data: NonNullable<Json>
          id?: never
          record_id: string
          table_name: string
          version: number
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          data?: NonNullable<Json>
          id?: never
          record_id?: string
          table_name?: string
          version?: number
        }
        Relationships: []
      }
      compliance_reports: {
        Row: {
          created_at: string
          file_content: string
          generated_by: string | null
          id: string
          period: string
          range: string
        }
        Insert: {
          created_at?: string
          file_content: string
          generated_by?: string | null
          id?: string
          period: string
          range?: string
        }
        Update: {
          created_at?: string
          file_content?: string
          generated_by?: string | null
          id?: string
          period?: string
          range?: string
        }
        Relationships: []
      }
      departments: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          leader_id: string | null
          name: string
          parent_id: string | null
          sort_order: number
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          leader_id?: string | null
          name: string
          parent_id?: string | null
          sort_order?: number
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          leader_id?: string | null
          name?: string
          parent_id?: string | null
          sort_order?: number
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "departments_leader_id_fkey"
            columns: ["leader_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
        ]
      }
      export_jobs: {
        Row: {
          config: NonNullable<Json>
          content: string | null
          created_at: string
          error: string | null
          file_path: string | null
          finished_at: string | null
          id: string
          requested_by: string
          size_bytes: number | null
          source: string
          started_at: string | null
          status: string
        }
        Insert: {
          config?: NonNullable<Json>
          content?: string | null
          created_at?: string
          error?: string | null
          file_path?: string | null
          finished_at?: string | null
          id?: string
          requested_by: string
          size_bytes?: number | null
          source: string
          started_at?: string | null
          status?: string
        }
        Update: {
          config?: NonNullable<Json>
          content?: string | null
          created_at?: string
          error?: string | null
          file_path?: string | null
          finished_at?: string | null
          id?: string
          requested_by?: string
          size_bytes?: number | null
          source?: string
          started_at?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "export_jobs_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "export_jobs_source_fkey"
            columns: ["source"]
            isOneToOne: false
            referencedRelation: "export_sources"
            referencedColumns: ["source"]
          },
        ]
      }
      export_sources: {
        Row: {
          config_schema: NonNullable<Json>
          created_at: string
          enabled: boolean
          owner_module: string
          source: string
        }
        Insert: {
          config_schema?: NonNullable<Json>
          created_at?: string
          enabled?: boolean
          owner_module: string
          source: string
        }
        Update: {
          config_schema?: NonNullable<Json>
          created_at?: string
          enabled?: boolean
          owner_module?: string
          source?: string
        }
        Relationships: []
      }
      form_renderers: {
        Row: {
          created_at: string
          module: string
          ref_type: string
          renderer_key: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          module: string
          ref_type: string
          renderer_key: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          module?: string
          ref_type?: string
          renderer_key?: string
          updated_at?: string
        }
        Relationships: []
      }
      im_auth_configs: {
        Row: {
          credentials: string | null
          enabled: boolean
          provider: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          credentials?: string | null
          enabled?: boolean
          provider: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          credentials?: string | null
          enabled?: boolean
          provider?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      integration_call_logs: {
        Row: {
          created_at: string
          duration_ms: number | null
          error: string | null
          id: number
          key_id: string | null
          kind: string
          method_event: string
          request_excerpt: string | null
          response_excerpt: string | null
          status_code: number | null
          webhook_id: string | null
        }
        Insert: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          key_id?: string | null
          kind: string
          method_event: string
          request_excerpt?: string | null
          response_excerpt?: string | null
          status_code?: number | null
          webhook_id?: string | null
        }
        Update: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          key_id?: string | null
          kind?: string
          method_event?: string
          request_excerpt?: string | null
          response_excerpt?: string | null
          status_code?: number | null
          webhook_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "integration_call_logs_key_id_fkey"
            columns: ["key_id"]
            isOneToOne: false
            referencedRelation: "api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_call_logs_webhook_id_fkey"
            columns: ["webhook_id"]
            isOneToOne: false
            referencedRelation: "webhooks"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_call_logs_2026_10: {
        Row: {
          created_at: string
          duration_ms: number | null
          error: string | null
          id: number
          key_id: string | null
          kind: string
          method_event: string
          request_excerpt: string | null
          response_excerpt: string | null
          status_code: number | null
          webhook_id: string | null
        }
        Insert: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          key_id?: string | null
          kind: string
          method_event: string
          request_excerpt?: string | null
          response_excerpt?: string | null
          status_code?: number | null
          webhook_id?: string | null
        }
        Update: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          key_id?: string | null
          kind?: string
          method_event?: string
          request_excerpt?: string | null
          response_excerpt?: string | null
          status_code?: number | null
          webhook_id?: string | null
        }
        Relationships: []
      }
      integration_call_logs_2026_11: {
        Row: {
          created_at: string
          duration_ms: number | null
          error: string | null
          id: number
          key_id: string | null
          kind: string
          method_event: string
          request_excerpt: string | null
          response_excerpt: string | null
          status_code: number | null
          webhook_id: string | null
        }
        Insert: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          key_id?: string | null
          kind: string
          method_event: string
          request_excerpt?: string | null
          response_excerpt?: string | null
          status_code?: number | null
          webhook_id?: string | null
        }
        Update: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          key_id?: string | null
          kind?: string
          method_event?: string
          request_excerpt?: string | null
          response_excerpt?: string | null
          status_code?: number | null
          webhook_id?: string | null
        }
        Relationships: []
      }
      integration_call_stats_daily: {
        Row: {
          avg_duration_ms: number | null
          day: string
          failed: number
          kind: string
          ref_id: string
          ref_name: string | null
          total: number
          updated_at: string
        }
        Insert: {
          avg_duration_ms?: number | null
          day: string
          failed?: number
          kind: string
          ref_id?: string
          ref_name?: string | null
          total?: number
          updated_at?: string
        }
        Update: {
          avg_duration_ms?: number | null
          day?: string
          failed?: number
          kind?: string
          ref_id?: string
          ref_name?: string | null
          total?: number
          updated_at?: string
        }
        Relationships: []
      }
      integration_events: {
        Row: {
          attempts: number
          created_at: string
          event: string
          id: number
          next_retry_at: string
          payload: NonNullable<Json>
          status: string
        }
        Insert: {
          attempts?: number
          created_at?: string
          event: string
          id?: never
          next_retry_at?: string
          payload?: NonNullable<Json>
          status?: string
        }
        Update: {
          attempts?: number
          created_at?: string
          event?: string
          id?: never
          next_retry_at?: string
          payload?: NonNullable<Json>
          status?: string
        }
        Relationships: []
      }
      menu_items: {
        Row: {
          created_at: string
          key: string
          label: string
          module: string
          parent_key: string | null
          route: string | null
          sort_order: number
        }
        Insert: {
          created_at?: string
          key: string
          label: string
          module: string
          parent_key?: string | null
          route?: string | null
          sort_order?: number
        }
        Update: {
          created_at?: string
          key?: string
          label?: string
          module?: string
          parent_key?: string | null
          route?: string | null
          sort_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "menu_items_parent_key_fkey"
            columns: ["parent_key"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["key"]
          },
        ]
      }
      message_deliveries: {
        Row: {
          attempts: number
          channel: string
          created_at: string
          error: string | null
          event_key: string
          id: number
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body: string | null
          rendered_subject: string | null
          response: string | null
          status: string
        }
        Insert: {
          attempts?: number
          channel: string
          created_at?: string
          error?: string | null
          event_key: string
          id?: never
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body?: string | null
          rendered_subject?: string | null
          response?: string | null
          status: string
        }
        Update: {
          attempts?: number
          channel?: string
          created_at?: string
          error?: string | null
          event_key?: string
          id?: never
          idempotency_key?: string
          message_id?: number
          recipient_id?: string
          rendered_body?: string | null
          rendered_subject?: string | null
          response?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "message_deliveries_message_id_fkey"
            columns: ["message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "message_deliveries_recipient_id_fkey"
            columns: ["recipient_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      message_deliveries_202610: {
        Row: {
          attempts: number
          channel: string
          created_at: string
          error: string | null
          event_key: string
          id: number
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body: string | null
          rendered_subject: string | null
          response: string | null
          status: string
        }
        Insert: {
          attempts?: number
          channel: string
          created_at?: string
          error?: string | null
          event_key: string
          id?: never
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body?: string | null
          rendered_subject?: string | null
          response?: string | null
          status: string
        }
        Update: {
          attempts?: number
          channel?: string
          created_at?: string
          error?: string | null
          event_key?: string
          id?: never
          idempotency_key?: string
          message_id?: number
          recipient_id?: string
          rendered_body?: string | null
          rendered_subject?: string | null
          response?: string | null
          status?: string
        }
        Relationships: []
      }
      message_deliveries_202611: {
        Row: {
          attempts: number
          channel: string
          created_at: string
          error: string | null
          event_key: string
          id: number
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body: string | null
          rendered_subject: string | null
          response: string | null
          status: string
        }
        Insert: {
          attempts?: number
          channel: string
          created_at?: string
          error?: string | null
          event_key: string
          id?: never
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body?: string | null
          rendered_subject?: string | null
          response?: string | null
          status: string
        }
        Update: {
          attempts?: number
          channel?: string
          created_at?: string
          error?: string | null
          event_key?: string
          id?: never
          idempotency_key?: string
          message_id?: number
          recipient_id?: string
          rendered_body?: string | null
          rendered_subject?: string | null
          response?: string | null
          status?: string
        }
        Relationships: []
      }
      message_event_registry: {
        Row: {
          available_vars: NonNullable<Json>
          created_at: string
          description: string | null
          event_key: string
          module: string
          registered_by: string | null
        }
        Insert: {
          available_vars?: NonNullable<Json>
          created_at?: string
          description?: string | null
          event_key: string
          module: string
          registered_by?: string | null
        }
        Update: {
          available_vars?: NonNullable<Json>
          created_at?: string
          description?: string | null
          event_key?: string
          module?: string
          registered_by?: string | null
        }
        Relationships: []
      }
      message_template_current: {
        Row: {
          channel: string
          event_key: string
          template_id: string
        }
        Insert: {
          channel: string
          event_key: string
          template_id: string
        }
        Update: {
          channel?: string
          event_key?: string
          template_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "message_template_current_event_fk"
            columns: ["event_key"]
            isOneToOne: false
            referencedRelation: "message_event_registry"
            referencedColumns: ["event_key"]
          },
          {
            foreignKeyName: "message_template_current_template_fk"
            columns: ["template_id", "event_key", "channel"]
            isOneToOne: false
            referencedRelation: "message_templates"
            referencedColumns: ["id", "event_key", "channel"]
          },
        ]
      }
      message_templates: {
        Row: {
          body_tpl: string
          channel: string
          created_at: string
          event_key: string
          id: string
          status: string
          subject_tpl: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        Insert: {
          body_tpl: string
          channel: string
          created_at?: string
          event_key: string
          id?: string
          status?: string
          subject_tpl: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Update: {
          body_tpl?: string
          channel?: string
          created_at?: string
          event_key?: string
          id?: string
          status?: string
          subject_tpl?: string
          updated_at?: string
          updated_by?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "message_templates_event_key_fkey"
            columns: ["event_key"]
            isOneToOne: false
            referencedRelation: "message_event_registry"
            referencedColumns: ["event_key"]
          },
        ]
      }
      messages: {
        Row: {
          body: string
          created_at: string
          event_key: string
          id: number
          read_at: string | null
          recipient_id: string
          ref_id: string | null
          ref_type: string | null
          source_module: string | null
          starred: boolean
          title: string
        }
        Insert: {
          body: string
          created_at?: string
          event_key: string
          id?: never
          read_at?: string | null
          recipient_id: string
          ref_id?: string | null
          ref_type?: string | null
          source_module?: string | null
          starred?: boolean
          title: string
        }
        Update: {
          body?: string
          created_at?: string
          event_key?: string
          id?: never
          read_at?: string | null
          recipient_id?: string
          ref_id?: string | null
          ref_type?: string | null
          source_module?: string | null
          starred?: boolean
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "messages_recipient_id_fkey"
            columns: ["recipient_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      positions: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          department_id: string | null
          description: string | null
          headcount: number
          id: string
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          description?: string | null
          headcount?: number
          id?: string
          name: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          description?: string | null
          headcount?: number
          id?: string
          name?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "positions_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          created_at: string
          department: string | null
          department_id: string | null
          dingtalk_userid: string | null
          email: string | null
          feishu_userid: string | null
          full_name: string | null
          id: string
          position_id: string | null
          role: Database["public"]["Enums"]["user_role"]
          role_id: string | null
          status: Database["public"]["Enums"]["profile_status"]
          updated_at: string
          updated_by: string | null
          wecom_userid: string | null
        }
        Insert: {
          created_at?: string
          department?: string | null
          department_id?: string | null
          dingtalk_userid?: string | null
          email?: string | null
          feishu_userid?: string | null
          full_name?: string | null
          id: string
          position_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          role_id?: string | null
          status?: Database["public"]["Enums"]["profile_status"]
          updated_at?: string
          updated_by?: string | null
          wecom_userid?: string | null
        }
        Update: {
          created_at?: string
          department?: string | null
          department_id?: string | null
          dingtalk_userid?: string | null
          email?: string | null
          feishu_userid?: string | null
          full_name?: string | null
          id?: string
          position_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          role_id?: string | null
          status?: Database["public"]["Enums"]["profile_status"]
          updated_at?: string
          updated_by?: string | null
          wecom_userid?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "profiles_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions_v"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles_v"
            referencedColumns: ["id"]
          },
        ]
      }
      report_allowed_views: {
        Row: {
          allowed_columns: NonNullable<Json>
          created_at: string
          registered_by: string | null
          view_name: string
        }
        Insert: {
          allowed_columns: NonNullable<Json>
          created_at?: string
          registered_by?: string | null
          view_name: string
        }
        Update: {
          allowed_columns?: NonNullable<Json>
          created_at?: string
          registered_by?: string | null
          view_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "report_allowed_views_registered_by_fkey"
            columns: ["registered_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      report_definitions: {
        Row: {
          config: NonNullable<Json>
          created_at: string
          created_by: string | null
          id: string
          name: string
          owner_id: string
          source_view: string
          updated_at: string
          updated_by: string | null
          visibility: string
        }
        Insert: {
          config?: NonNullable<Json>
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          owner_id: string
          source_view: string
          updated_at?: string
          updated_by?: string | null
          visibility?: string
        }
        Update: {
          config?: NonNullable<Json>
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          owner_id?: string
          source_view?: string
          updated_at?: string
          updated_by?: string | null
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "report_definitions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "report_definitions_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "report_definitions_source_view_fkey"
            columns: ["source_view"]
            isOneToOne: false
            referencedRelation: "report_allowed_views"
            referencedColumns: ["view_name"]
          },
          {
            foreignKeyName: "report_definitions_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      report_subscription_runs: {
        Row: {
          created_at: string
          duration_ms: number | null
          error: string | null
          id: number
          status: string
          subscription_id: string
        }
        Insert: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          status?: string
          subscription_id: string
        }
        Update: {
          created_at?: string
          duration_ms?: number | null
          error?: string | null
          id?: never
          status?: string
          subscription_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "report_subscription_runs_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "report_subscriptions"
            referencedColumns: ["id"]
          },
        ]
      }
      report_subscriptions: {
        Row: {
          channels: string[]
          created_at: string
          created_by: string
          cron_expr: string
          id: string
          is_deleted: boolean
          recipients: string
          report_def_id: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          channels?: string[]
          created_at?: string
          created_by: string
          cron_expr: string
          id?: string
          is_deleted?: boolean
          recipients?: string
          report_def_id: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          channels?: string[]
          created_at?: string
          created_by?: string
          cron_expr?: string
          id?: string
          is_deleted?: boolean
          recipients?: string
          report_def_id?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "report_subscriptions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "report_subscriptions_report_def_id_fkey"
            columns: ["report_def_id"]
            isOneToOne: false
            referencedRelation: "report_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "report_subscriptions_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      role_data_scopes: {
        Row: {
          role_id: string
          scope: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          role_id: string
          scope: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          role_id?: string
          scope?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "role_data_scopes_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: true
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "role_data_scopes_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: true
            referencedRelation: "roles_v"
            referencedColumns: ["id"]
          },
        ]
      }
      role_menu_grants: {
        Row: {
          granted_at: string
          granted_by: string | null
          menu_key: string
          role_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          menu_key: string
          role_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          menu_key?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "role_menu_grants_menu_key_fkey"
            columns: ["menu_key"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "role_menu_grants_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "role_menu_grants_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles_v"
            referencedColumns: ["id"]
          },
        ]
      }
      roles: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          is_builtin: boolean
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          is_builtin?: boolean
          name: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          is_builtin?: boolean
          name?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      sync_conflicts: {
        Row: {
          created_at: string
          id: string
          resolution: string
          resolved_at: string | null
          resolved_by: string | null
          row_key: string
          run_id: string
          source_data: NonNullable<Json>
          target_data: Json | null
        }
        Insert: {
          created_at?: string
          id?: string
          resolution?: string
          resolved_at?: string | null
          resolved_by?: string | null
          row_key: string
          run_id: string
          source_data: NonNullable<Json>
          target_data?: Json | null
        }
        Update: {
          created_at?: string
          id?: string
          resolution?: string
          resolved_at?: string | null
          resolved_by?: string | null
          row_key?: string
          run_id?: string
          source_data?: NonNullable<Json>
          target_data?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "sync_conflicts_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "sync_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      sync_runs: {
        Row: {
          error: string | null
          executed_by: string | null
          finished_at: string | null
          id: string
          started_at: string
          stats: NonNullable<Json>
          status: string
          task_id: string
          trigger_type: string
        }
        Insert: {
          error?: string | null
          executed_by?: string | null
          finished_at?: string | null
          id?: string
          started_at?: string
          stats?: NonNullable<Json>
          status?: string
          task_id: string
          trigger_type?: string
        }
        Update: {
          error?: string | null
          executed_by?: string | null
          finished_at?: string | null
          id?: string
          started_at?: string
          stats?: NonNullable<Json>
          status?: string
          task_id?: string
          trigger_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "sync_runs_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "sync_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      sync_schedules: {
        Row: {
          created_at: string
          created_by: string | null
          cron_expr: string | null
          id: string
          last_run_at: string | null
          next_run_at: string | null
          status: string
          task_id: string
          timezone: string
          trigger_type: string
          updated_at: string
          updated_by: string | null
          webhook_token_hash: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          cron_expr?: string | null
          id?: string
          last_run_at?: string | null
          next_run_at?: string | null
          status?: string
          task_id: string
          timezone?: string
          trigger_type?: string
          updated_at?: string
          updated_by?: string | null
          webhook_token_hash?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          cron_expr?: string | null
          id?: string
          last_run_at?: string | null
          next_run_at?: string | null
          status?: string
          task_id?: string
          timezone?: string
          trigger_type?: string
          updated_at?: string
          updated_by?: string | null
          webhook_token_hash?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sync_schedules_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: true
            referencedRelation: "sync_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      sync_sources: {
        Row: {
          config: NonNullable<Json>
          created_at: string
          created_by: string | null
          credentials: string | null
          id: string
          last_verified_at: string | null
          name: string
          status: string
          type: string
          updated_at: string
          updated_by: string | null
          verify_status: string
        }
        Insert: {
          config?: NonNullable<Json>
          created_at?: string
          created_by?: string | null
          credentials?: string | null
          id?: string
          last_verified_at?: string | null
          name: string
          status?: string
          type: string
          updated_at?: string
          updated_by?: string | null
          verify_status?: string
        }
        Update: {
          config?: NonNullable<Json>
          created_at?: string
          created_by?: string | null
          credentials?: string | null
          id?: string
          last_verified_at?: string | null
          name?: string
          status?: string
          type?: string
          updated_at?: string
          updated_by?: string | null
          verify_status?: string
        }
        Relationships: []
      }
      sync_task_versions: {
        Row: {
          config: NonNullable<Json>
          created_at: string
          created_by: string | null
          task_id: string
          version: number
        }
        Insert: {
          config: NonNullable<Json>
          created_at?: string
          created_by?: string | null
          task_id: string
          version: number
        }
        Update: {
          config?: NonNullable<Json>
          created_at?: string
          created_by?: string | null
          task_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "sync_task_versions_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "sync_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      sync_tasks: {
        Row: {
          config_version: number
          conflict_policy: string
          created_at: string
          created_by: string | null
          direction: string
          field_mapping: NonNullable<Json>
          id: string
          name: string
          source_id: string
          status: string
          target_table: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          config_version?: number
          conflict_policy?: string
          created_at?: string
          created_by?: string | null
          direction?: string
          field_mapping: NonNullable<Json>
          id?: string
          name: string
          source_id: string
          status?: string
          target_table: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          config_version?: number
          conflict_policy?: string
          created_at?: string
          created_by?: string | null
          direction?: string
          field_mapping?: NonNullable<Json>
          id?: string
          name?: string
          source_id?: string
          status?: string
          target_table?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sync_tasks_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "sync_sources"
            referencedColumns: ["id"]
          },
        ]
      }
      system_announcements: {
        Row: {
          audience: string
          content: string
          created_at: string
          created_by: string | null
          ends_at: string | null
          id: string
          pinned: boolean
          published_at: string | null
          published_by: string | null
          starts_at: string | null
          status: string
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          audience?: string
          content: string
          created_at?: string
          created_by?: string | null
          ends_at?: string | null
          id?: string
          pinned?: boolean
          published_at?: string | null
          published_by?: string | null
          starts_at?: string | null
          status?: string
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          audience?: string
          content?: string
          created_at?: string
          created_by?: string | null
          ends_at?: string | null
          id?: string
          pinned?: boolean
          published_at?: string | null
          published_by?: string | null
          starts_at?: string | null
          status?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      system_cron_registry: {
        Row: {
          created_at: string
          cron_expr: string
          id: number
          job_name: string
          last_result: string | null
          last_run_at: string | null
          module: string
          owner_route: string
          registered_by: string | null
          status: string
          timezone: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          cron_expr: string
          id?: never
          job_name: string
          last_result?: string | null
          last_run_at?: string | null
          module: string
          owner_route: string
          registered_by?: string | null
          status?: string
          timezone?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          cron_expr?: string
          id?: never
          job_name?: string
          last_result?: string | null
          last_run_at?: string | null
          module?: string
          owner_route?: string
          registered_by?: string | null
          status?: string
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      system_dict_meta: {
        Row: {
          created_at: string
          created_by: string | null
          description: string
          dict_key: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          description: string
          dict_key: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          description?: string
          dict_key?: string
        }
        Relationships: []
      }
      system_dictionaries: {
        Row: {
          color_class: string | null
          dict_key: string
          label: string
          sort_order: number
          status: string
          updated_at: string
          updated_by: string | null
          value: string
        }
        Insert: {
          color_class?: string | null
          dict_key: string
          label: string
          sort_order?: number
          status?: string
          updated_at?: string
          updated_by?: string | null
          value: string
        }
        Update: {
          color_class?: string | null
          dict_key?: string
          label?: string
          sort_order?: number
          status?: string
          updated_at?: string
          updated_by?: string | null
          value?: string
        }
        Relationships: []
      }
      system_services: {
        Row: {
          config: NonNullable<Json>
          credentials: string | null
          service: string
          updated_at: string
          updated_by: string | null
          verified_at: string | null
          verify_status: string
        }
        Insert: {
          config?: NonNullable<Json>
          credentials?: string | null
          service: string
          updated_at?: string
          updated_by?: string | null
          verified_at?: string | null
          verify_status?: string
        }
        Update: {
          config?: NonNullable<Json>
          credentials?: string | null
          service?: string
          updated_at?: string
          updated_by?: string | null
          verified_at?: string | null
          verify_status?: string
        }
        Relationships: []
      }
      system_setting_history: {
        Row: {
          changed_at: string
          changed_by: string | null
          id: number
          key: string
          new_value: NonNullable<Json>
          old_value: Json | null
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          id?: never
          key: string
          new_value: NonNullable<Json>
          old_value?: Json | null
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          id?: never
          key?: string
          new_value?: NonNullable<Json>
          old_value?: Json | null
        }
        Relationships: []
      }
      system_settings: {
        Row: {
          description: string
          group_name: string
          key: string
          updated_at: string
          updated_by: string | null
          value: NonNullable<Json>
          value_type: string
        }
        Insert: {
          description: string
          group_name: string
          key: string
          updated_at?: string
          updated_by?: string | null
          value: NonNullable<Json>
          value_type: string
        }
        Update: {
          description?: string
          group_name?: string
          key?: string
          updated_at?: string
          updated_by?: string | null
          value?: NonNullable<Json>
          value_type?: string
        }
        Relationships: []
      }
      system_sms_templates: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          name: string
          provider_code: string
          scene: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          provider_code: string
          scene: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          provider_code?: string
          scene?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      webhook_deliveries: {
        Row: {
          attempt_no: number
          attempted_at: string
          duration_ms: number | null
          error: string | null
          event_id: number
          finished_at: string | null
          http_status: number | null
          id: number
          request_id: number | null
          status: string
          webhook_id: string
        }
        Insert: {
          attempt_no?: number
          attempted_at?: string
          duration_ms?: number | null
          error?: string | null
          event_id: number
          finished_at?: string | null
          http_status?: number | null
          id?: never
          request_id?: number | null
          status?: string
          webhook_id: string
        }
        Update: {
          attempt_no?: number
          attempted_at?: string
          duration_ms?: number | null
          error?: string | null
          event_id?: number
          finished_at?: string | null
          http_status?: number | null
          id?: never
          request_id?: number | null
          status?: string
          webhook_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_deliveries_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "integration_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_deliveries_webhook_id_fkey"
            columns: ["webhook_id"]
            isOneToOne: false
            referencedRelation: "webhooks"
            referencedColumns: ["id"]
          },
        ]
      }
      webhooks: {
        Row: {
          created_at: string
          created_by: string | null
          events: string[]
          headers_enc: string | null
          id: string
          name: string
          retry_policy: NonNullable<Json>
          secret_enc: string
          status: string
          updated_at: string
          updated_by: string | null
          url: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          events: string[]
          headers_enc?: string | null
          id?: string
          name: string
          retry_policy?: NonNullable<Json>
          secret_enc: string
          status?: string
          updated_at?: string
          updated_by?: string | null
          url: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          events?: string[]
          headers_enc?: string | null
          id?: string
          name?: string
          retry_policy?: NonNullable<Json>
          secret_enc?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
          url?: string
        }
        Relationships: []
      }
    }
    Views: {
      audit_denied_v: {
        Row: {
          module: string | null
          reason: string | null
          route: string | null
          time: string | null
          user_id: string | null
          user_name: string | null
        }
        Relationships: []
      }
      audit_operations_v: {
        Row: {
          action: string | null
          actor_id: string | null
          actor_name: string | null
          created_at: string | null
          diff: Json | null
          id: number | null
          ip: unknown
          module: string | null
          object_id: string | null
          object_type: string | null
          ua: string | null
        }
        Relationships: []
      }
      departments_v: {
        Row: {
          created_at: string | null
          created_by: string | null
          depth: number | null
          id: string | null
          leader_id: string | null
          name: string | null
          parent_id: string | null
          path: string | null
          sort_order: number | null
          status: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Relationships: []
      }
      positions_v: {
        Row: {
          code: string | null
          created_at: string | null
          created_by: string | null
          department_id: string | null
          department_name: string | null
          description: string | null
          headcount: number | null
          id: string | null
          name: string | null
          staff_count: number | null
          status: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Relationships: [
          {
            foreignKeyName: "positions_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
        ]
      }
      published_announcements_v: {
        Row: {
          audience: string | null
          content: string | null
          ends_at: string | null
          id: string | null
          pinned: boolean | null
          published_at: string | null
          starts_at: string | null
          title: string | null
          updated_at: string | null
        }
        Insert: {
          audience?: string | null
          content?: string | null
          ends_at?: string | null
          id?: string | null
          pinned?: boolean | null
          published_at?: string | null
          starts_at?: string | null
          title?: string | null
          updated_at?: string | null
        }
        Update: {
          audience?: string | null
          content?: string | null
          ends_at?: string | null
          id?: string | null
          pinned?: boolean | null
          published_at?: string | null
          starts_at?: string | null
          title?: string | null
          updated_at?: string | null
        }
        Relationships: []
      }
      roles_v: {
        Row: {
          code: string | null
          created_at: string | null
          created_by: string | null
          description: string | null
          id: string | null
          is_builtin: boolean | null
          name: string | null
          status: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          description?: string | null
          id?: string | null
          is_builtin?: boolean | null
          name?: string | null
          status?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          description?: string | null
          id?: string | null
          is_builtin?: boolean | null
          name?: string | null
          status?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: []
      }
      system_cron_jobs_v: {
        Row: {
          created_at: string | null
          cron_expr: string | null
          expected_interval_minutes: number | null
          failure_rate_24h: number | null
          failures_24h: number | null
          is_orphan: boolean | null
          is_scheduled: boolean | null
          job_name: string | null
          last_result: string | null
          last_run_at: string | null
          module: string | null
          overdue: boolean | null
          owner_route: string | null
          registered_by: string | null
          registry_id: number | null
          runs_24h: number | null
          status: string | null
          timezone: string | null
          updated_at: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      act_task: {
        Args: { p_action: string; p_comment: string; p_task_id: string }
        Returns: {
          created_at: string
          current_seq: number
          flow_version_id: string
          form_data: NonNullable<Json>
          id: string
          initiator_id: string
          last_urged_at: string | null
          module: string
          ref_id: string | null
          ref_type: string | null
          status: string
          template_version_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "approval_instances"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_update_profile: {
        Args: {
          p_clear_department?: boolean
          p_clear_position?: boolean
          p_department?: string
          p_department_id?: string
          p_full_name?: string
          p_position_id?: string
          p_role?: Database["public"]["Enums"]["user_role"]
          p_status?: Database["public"]["Enums"]["profile_status"]
          p_user_id: string
        }
        Returns: {
          created_at: string
          department: string | null
          department_id: string | null
          email: string | null
          full_name: string | null
          id: string
          position_id: string | null
          role: Database["public"]["Enums"]["user_role"]
          role_id: string | null
          status: Database["public"]["Enums"]["profile_status"]
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "profiles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      api_departments: {
        Args: { p_token: string }
        Returns: {
          created_at: string | null
          created_by: string | null
          depth: number | null
          id: string | null
          leader_id: string | null
          name: string | null
          parent_id: string | null
          path: string | null
          sort_order: number | null
          status: string | null
          updated_at: string | null
          updated_by: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "departments_v"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      approval_usage_counts: {
        Args: Record<PropertyKey, never>
        Returns: {
          flow_version_id: string
          running_count: number
          template_version_id: string
          total_count: number
        }[]
      }
      assign_role: {
        Args: { p_new_role: string; p_target_user: string }
        Returns: {
          created_at: string
          department: string | null
          department_id: string | null
          email: string | null
          full_name: string | null
          id: string
          position_id: string | null
          role: Database["public"]["Enums"]["user_role"]
          role_id: string | null
          status: Database["public"]["Enums"]["profile_status"]
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "profiles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_api_key: {
        Args: { p_expires_at: string; p_name: string; p_scopes: Json }
        Returns: Json
      }
      create_webhook: {
        Args: {
          p_events: string[]
          p_headers?: Json
          p_name: string
          p_retry_policy?: Json
          p_url: string
        }
        Returns: Json
      }
      delete_department: {
        Args: { p_id: string }
        Returns: {
          created_at: string
          created_by: string | null
          id: string
          leader_id: string | null
          name: string
          parent_id: string | null
          sort_order: number
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "departments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      delete_position: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          department_id: string | null
          description: string | null
          headcount: number
          id: string
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "positions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      delete_report_definition: {
        Args: { p_def_id: string }
        Returns: undefined
      }
      delete_report_subscription: {
        Args: { p_subscription_id: string }
        Returns: undefined
      }
      delete_role: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          is_builtin: boolean
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "roles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      department_headcount: {
        Args: Record<PropertyKey, never>
        Returns: {
          department_id: string
          headcount: number
          name: string
          path: string
          position_headcount: number
        }[]
      }
      department_tree: {
        Args: Record<PropertyKey, never>
        Returns: {
          created_at: string | null
          created_by: string | null
          depth: number | null
          id: string | null
          leader_id: string | null
          name: string | null
          parent_id: string | null
          path: string | null
          sort_order: number | null
          status: string | null
          updated_at: string | null
          updated_by: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "departments_v"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      disable_department: {
        Args: { p_id: string }
        Returns: {
          created_at: string
          created_by: string | null
          id: string
          leader_id: string | null
          name: string
          parent_id: string | null
          sort_order: number
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "departments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      disable_dict_item: {
        Args: { p_dict_key: string; p_value: string }
        Returns: Json
      }
      disable_flow: {
        Args: { p_id: string }
        Returns: {
          branches: Json | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          nodes: NonNullable<Json>
          status: string
          template_id: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_flows"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      disable_form_template: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          module: string
          name: string
          schema: NonNullable<Json>
          status: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_form_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      disable_position: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          department_id: string | null
          description: string | null
          headcount: number
          id: string
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "positions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      disable_role: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          is_builtin: boolean
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "roles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      disable_sms_template: { Args: { p_id: string }; Returns: Json }
      disable_sync_source: { Args: { p_id: string }; Returns: Json }
      disable_webhook: { Args: { p_id: string }; Returns: Json }
      download_export: { Args: { p_job_id: string }; Returns: string }
      dry_run_sync_task: {
        Args: { p_sample: Json; p_task_id: string }
        Returns: Json
      }
      enable_department: {
        Args: { p_id: string }
        Returns: {
          created_at: string
          created_by: string | null
          id: string
          leader_id: string | null
          name: string
          parent_id: string | null
          sort_order: number
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "departments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      enable_position: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          department_id: string | null
          description: string | null
          headcount: number
          id: string
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "positions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      enable_role: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          is_builtin: boolean
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "roles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      enable_webhook: { Args: { p_id: string }; Returns: Json }
      generate_compliance_report: {
        Args: { p_period: string; p_range?: string }
        Returns: string
      }
      get_all_settings: {
        Args: Record<PropertyKey, never>
        Returns: {
          description: string
          group_name: string
          key: string
          updated_at: string
          updated_by: string
          value: Json
          value_type: string
        }[]
      }
      get_announcements: {
        Args: Record<PropertyKey, never>
        Returns: {
          audience: string
          content: string
          creator_name: string
          ends_at: string
          id: string
          pinned: boolean
          published_at: string
          publisher_name: string
          starts_at: string
          status: string
          title: string
          updated_at: string
        }[]
      }
      get_api_key_usage: { Args: { p_key_id: string }; Returns: Json }
      get_cron_run_history: {
        Args: { p_job_name?: string; p_limit?: number }
        Returns: {
          duration_ms: number
          end_time: string
          job_name: string
          job_pid: number
          return_message: string
          runid: number
          start_time: string
          status: string
        }[]
      }
      get_dashboard_stats: {
        Args: Record<PropertyKey, never>
        Returns: Json
      }
      get_dict: { Args: { p_dict_key: string }; Returns: Json }
      get_dict_catalog: {
        Args: Record<PropertyKey, never>
        Returns: {
          active_count: number
          description: string
          dict_key: string
          item_count: number
        }[]
      }
      get_dict_items: {
        Args: { p_dict_key: string }
        Returns: {
          color_class: string
          label: string
          sort_order: number
          status: string
          updated_at: string
          updated_by: string
          value: string
        }[]
      }
      get_push_status: {
        Args: Record<PropertyKey, never>
        Returns: {
          channel: string
          enabled: boolean
          secret_masked: string
          webhook_url: string
        }[]
      }
      get_report_subscriptions: {
        Args: Record<PropertyKey, never>
        Returns: {
          channels: string[]
          created_at: string
          cron_expr: string
          id: string
          last_run_at: string
          last_run_duration_ms: number
          last_run_status: string
          next_run_at: string
          recipients: string
          report_def_id: string
          report_name: string
          report_visibility: string
          status: string
          updated_at: string
        }[]
      }
      get_role_user_counts: {
        Args: Record<PropertyKey, never>
        Returns: {
          role_code: string
          role_id: string
          user_count: number
        }[]
      }
      get_row_versions: {
        Args: { p_record_id: string; p_table: string }
        Returns: {
          change_type: string
          changed_at: string
          changed_by: string
          changed_by_name: string
          data: Json
          id: number
          version: number
        }[]
      }
      get_service_status: {
        Args: Record<PropertyKey, never>
        Returns: {
          config: Json
          credentials_masked: string
          service: string
          updated_at: string
          updated_by: string
          verified_at: string
          verify_status: string
        }[]
      }
      get_setting: { Args: { p_key: string }; Returns: Json }
      get_setting_history: {
        Args: { p_key: string }
        Returns: {
          changed_at: string
          changed_by: string
          changed_by_name: string
          id: number
          key: string
          new_value: Json
          old_value: Json
        }[]
      }
      get_storage_usage: {
        Args: Record<PropertyKey, never>
        Returns: {
          bucket_id: string
          object_count: number
          total_bytes: number
        }[]
      }
      get_sync_run_conflicts: {
        Args: { p_run_id: string }
        Returns: {
          created_at: string
          id: string
          resolution: string
          resolved_at: string
          resolved_by: string
          resolved_by_name: string
          row_key: string
          run_id: string
          source_data: Json
          target_data: Json
        }[]
      }
      get_sync_runs: {
        Args: { p_limit?: number; p_offset?: number; p_task_id?: string }
        Returns: {
          error: string
          executed_by: string
          executed_by_name: string
          finished_at: string
          id: string
          pending_conflicts: number
          started_at: string
          stats: Json
          status: string
          target_table: string
          task_id: string
          task_name: string
          trigger_type: string
        }[]
      }
      get_sync_schedules: {
        Args: Record<PropertyKey, never>
        Returns: {
          created_at: string
          cron_expr: string
          has_token: boolean
          id: string
          last_run_at: string
          last_run_status: string
          next_run_at: string
          source_name: string
          status: string
          target_table: string
          task_id: string
          task_name: string
          timezone: string
          trigger_type: string
          updated_at: string
        }[]
      }
      get_sync_sources: {
        Args: Record<PropertyKey, never>
        Returns: {
          config: Json
          created_at: string
          created_by: string
          credentials_masked: string
          id: string
          last_verified_at: string
          name: string
          status: string
          type: string
          updated_at: string
          updated_by: string
          verify_status: string
        }[]
      }
      get_sync_task_run_summaries: {
        Args: Record<PropertyKey, never>
        Returns: {
          finished_at: string
          run_id: string
          started_at: string
          stats: Json
          status: string
          task_id: string
          trigger_type: string
        }[]
      }
      get_sync_task_versions: {
        Args: { p_task_id: string }
        Returns: {
          config: Json
          created_at: string
          created_by: string
          version: number
        }[]
      }
      get_sync_tasks: {
        Args: Record<PropertyKey, never>
        Returns: {
          config_version: number
          conflict_policy: string
          created_at: string
          created_by: string
          direction: string
          field_mapping: Json
          id: string
          name: string
          source_id: string
          source_name: string
          source_status: string
          source_type: string
          source_verify_status: string
          status: string
          target_table: string
          updated_at: string
          updated_by: string
        }[]
      }
      get_webhooks: {
        Args: Record<PropertyKey, never>
        Returns: {
          created_at: string
          created_by: string
          events: string[]
          headers_masked: Json
          id: string
          name: string
          retry_policy: Json
          status: string
          updated_at: string
          updated_by: string
          url: string
        }[]
      }
      im_admin_set_userid: {
        Args: { p_provider: string; p_user_id: string; p_userid: string }
        Returns: Json
      }
      im_bind_self: { Args: { p_provider: string; p_userid: string }; Returns: Json }
      im_clear_all_bindings: { Args: Record<PropertyKey, never>; Returns: Json }
      im_exchange_qr_ticket: { Args: { p_ticket: string }; Returns: Json }
      im_get_config: { Args: { p_provider: string }; Returns: Json }
      im_get_enabled_provider: { Args: Record<PropertyKey, never>; Returns: string }
      im_get_login_options: { Args: Record<PropertyKey, never>; Returns: Json }
      im_password_login_allowed: { Args: { p_email: string }; Returns: boolean }
      im_poll_qr_login: { Args: { p_ticket: string }; Returns: Json }
      im_qr_complete_login: {
        Args: {
          p_code: string
          p_provider: string
          p_redirect_uri: string
          p_ticket: string
        }
        Returns: Json
      }
      im_start_qr_login: {
        Args: { p_provider: string; p_redirect_uri: string }
        Returns: Json
      }
      im_switch_provider: { Args: { p_provider: string }; Returns: Json }
      im_test_config: {
        Args: { p_credentials?: Json; p_provider: string }
        Returns: Json
      }
      im_unbind: { Args: { p_provider: string; p_user_id: string }; Returns: Json }
      im_upsert_config: {
        Args: { p_credentials: Json; p_enabled: boolean; p_provider: string }
        Returns: Json
      }
      grant_menu: {
        Args: { p_menu_key: string; p_role_id: string }
        Returns: {
          granted_at: string
          granted_by: string | null
          menu_key: string
          role_id: string
        }
        SetofOptions: {
          from: "*"
          to: "role_menu_grants"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      instance_detail: {
        Args: { p_instance_id: string }
        Returns: {
          created_at: string
          current_seq: number
          form_data: Json
          initiator_id: string
          initiator_name: string
          instance_id: string
          instance_status: string
          last_urged_at: string
          module: string
          ref_id: string
          ref_type: string
          schema: Json
          tasks: Json
          title: string
          updated_at: string
        }[]
      }
      issue_api_token: { Args: { p_key: string }; Returns: Json }
      list_recent_changes: {
        Args: { p_limit?: number }
        Returns: {
          change_type: string
          changed_at: string
          changed_by_name: string
          record_id: string
          table_name: string
          version: number
        }[]
      }
      list_recent_versions: {
        Args: { p_limit?: number; p_table: string }
        Returns: {
          change_type: string
          changed_at: string
          changed_by: string
          changed_by_name: string
          data: Json
          id: number
          record_id: string
          version: number
        }[]
      }
      mark_all_read: { Args: Record<PropertyKey, never>; Returns: number }
      mark_cc_read: { Args: { p_instance_id: string }; Returns: string }
      mark_notification_read: {
        Args: { p_id: number }
        Returns: {
          body: string
          created_at: string
          event_key: string
          id: number
          read_at: string | null
          recipient_id: string
          ref_id: string | null
          ref_type: string | null
          source_module: string | null
          starred: boolean
          title: string
        }
        SetofOptions: {
          from: "*"
          to: "messages"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      mark_notification_unread: {
        Args: { p_id: number }
        Returns: {
          body: string
          created_at: string
          event_key: string
          id: number
          read_at: string | null
          recipient_id: string
          ref_id: string | null
          ref_type: string | null
          source_module: string | null
          starred: boolean
          title: string
        }
        SetofOptions: {
          from: "*"
          to: "messages"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      mark_service_verified: {
        Args: { p_note: string; p_ok: boolean; p_service: string }
        Returns: Json
      }
      my_ccs: {
        Args: { p_unread?: boolean }
        Returns: {
          cc_created_at: string
          cc_read_at: string
          current_assignee_id: string
          current_assignee_name: string
          current_seq: number
          current_task_id: string
          current_task_status: string
          form_data: Json
          initiator_id: string
          initiator_name: string
          instance_id: string
          instance_status: string
          module: string
          ref_id: string
          ref_type: string
          title: string
        }[]
      }
      my_instances: {
        Args: { p_limit?: number }
        Returns: {
          created_at: string
          current_acted_at: string
          current_assignee_id: string
          current_assignee_name: string
          current_comment: string
          current_seq: number
          current_task_id: string
          current_task_status: string
          form_data: Json
          instance_id: string
          instance_status: string
          last_urged_at: string
          module: string
          ref_id: string
          ref_type: string
          title: string
          updated_at: string
        }[]
      }
      my_todos: {
        Args: { p_limit?: number; p_pending?: boolean }
        Returns: {
          acted_at: string
          comment: string
          created_at: string
          current_seq: number
          form_data: Json
          initiator_id: string
          initiator_name: string
          instance_id: string
          instance_status: string
          module: string
          ref_id: string
          ref_type: string
          seq: number
          task_id: string
          task_status: string
          title: string
        }[]
      }
      new_flow_version: {
        Args: { p_id: string }
        Returns: {
          branches: Json | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          nodes: NonNullable<Json>
          status: string
          template_id: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_flows"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      new_form_template_version: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          module: string
          name: string
          schema: NonNullable<Json>
          status: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_form_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      offline_announcement: { Args: { p_id: string }; Returns: Json }
      org_stats: { Args: Record<PropertyKey, never>; Returns: Json }
      position_headcount: { Args: { p_position_id: string }; Returns: number }
      preview_scope: { Args: { p_user_id: string }; Returns: Json }
      publish_announcement: {
        Args: { p_id: string; p_notify?: boolean }
        Returns: Json
      }
      publish_api_doc: {
        Args: { p_changelog?: string; p_spec: Json; p_version: string }
        Returns: string
      }
      publish_flow: {
        Args: { p_id: string }
        Returns: {
          branches: Json | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          nodes: NonNullable<Json>
          status: string
          template_id: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_flows"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      publish_form_template: {
        Args: { p_id: string }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          module: string
          name: string
          schema: NonNullable<Json>
          status: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_form_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      publish_message_template: {
        Args: { p_id: string }
        Returns: {
          body_tpl: string
          channel: string
          created_at: string
          event_key: string
          id: string
          status: string
          subject_tpl: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "message_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      publish_report_definition: {
        Args: { p_def_id: string }
        Returns: {
          config: NonNullable<Json>
          created_at: string
          created_by: string | null
          id: string
          name: string
          owner_id: string
          source_view: string
          updated_at: string
          updated_by: string | null
          visibility: string
        }
        SetofOptions: {
          from: "*"
          to: "report_definitions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      recent_notifications: {
        Args: { p_limit?: number }
        Returns: {
          body: string
          created_at: string
          event_key: string
          id: number
          read_at: string | null
          recipient_id: string
          ref_id: string | null
          ref_type: string | null
          source_module: string | null
          starred: boolean
          title: string
        }[]
        SetofOptions: {
          from: "*"
          to: "messages"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      record_denied_attempt: {
        Args: { p_module: string; p_reason: string; p_route: string }
        Returns: number
      }
      record_login_attempt: {
        Args: { p_email: string; p_fail_reason?: string; p_success: boolean }
        Returns: number
      }
      register_allowed_view: {
        Args: { p_allowed_columns: Json; p_view_name: string }
        Returns: {
          allowed_columns: NonNullable<Json>
          created_at: string
          registered_by: string | null
          view_name: string
        }
        SetofOptions: {
          from: "*"
          to: "report_allowed_views"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      register_menu_item: {
        Args: {
          p_key: string
          p_label: string
          p_module: string
          p_parent_key: string
          p_route: string
          p_sort_order: number
        }
        Returns: {
          created_at: string
          key: string
          label: string
          module: string
          parent_key: string | null
          route: string | null
          sort_order: number
        }
        SetofOptions: {
          from: "*"
          to: "menu_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      request_export: {
        Args: { p_config?: Json; p_source: string }
        Returns: string
      }
      rerun_sync_task: {
        Args: { p_sample?: Json; p_task_id: string }
        Returns: string
      }
      resend_delivery: {
        Args: { p_delivery_id: number }
        Returns: {
          attempts: number
          channel: string
          created_at: string
          error: string | null
          event_key: string
          id: number
          idempotency_key: string
          message_id: number
          recipient_id: string
          rendered_body: string | null
          rendered_subject: string | null
          response: string | null
          status: string
        }
        SetofOptions: {
          from: "*"
          to: "message_deliveries"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      resolve_sync_conflict: {
        Args: { p_conflict_id: string; p_resolution: string }
        Returns: Json
      }
      retry_export: { Args: { p_job_id: string }; Returns: string }
      revoke_api_key: { Args: { p_id: string }; Returns: Json }
      revoke_menu: {
        Args: { p_menu_key: string; p_role_id: string }
        Returns: {
          granted_at: string
          granted_by: string | null
          menu_key: string
          role_id: string
        }
        SetofOptions: {
          from: "*"
          to: "role_menu_grants"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      rollback_message_template: {
        Args: { p_id: string }
        Returns: {
          body_tpl: string
          channel: string
          created_at: string
          event_key: string
          id: string
          status: string
          subject_tpl: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "message_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      rollback_sync_task: { Args: { p_task_id: string }; Returns: Json }
      run_report: { Args: { p_def_id: string }; Returns: Json }
      run_report_subscription_now: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      run_scheduled_sync: { Args: { p_task_id: string }; Returns: string }
      run_sync_task: {
        Args: { p_sample?: Json; p_task_id: string }
        Returns: string
      }
      save_report_definition: {
        Args: {
          p_config: Json
          p_id: string
          p_name: string
          p_source_view: string
        }
        Returns: {
          config: NonNullable<Json>
          created_at: string
          created_by: string | null
          id: string
          name: string
          owner_id: string
          source_view: string
          updated_at: string
          updated_by: string | null
          visibility: string
        }
        SetofOptions: {
          from: "*"
          to: "report_definitions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_report_subscription_status: {
        Args: { p_status: string; p_subscription_id: string }
        Returns: {
          channels: string[]
          created_at: string
          created_by: string
          cron_expr: string
          id: string
          is_deleted: boolean
          recipients: string
          report_def_id: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "report_subscriptions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_sync_schedule_status: {
        Args: { p_status: string; p_task_id: string }
        Returns: Json
      }
      signup_trend: {
        Args: { p_days?: number }
        Returns: {
          day: string
          count: number
        }[]
      }
      simulate_flow: {
        Args: { p_flow_id: string; p_form_data?: Json; p_initiator?: string }
        Returns: Json
      }
      submit_instance: {
        Args: {
          p_form_data: Json
          p_module: string
          p_ref_id: string
          p_ref_type: string
          p_template_code: string
        }
        Returns: string
      }
      test_mail_config: { Args: { p_to: string }; Returns: Json }
      test_push_config: { Args: { p_channel: string }; Returns: Json }
      test_sms_config: { Args: { p_phone: string }; Returns: Json }
      test_storage_config: { Args: Record<PropertyKey, never>; Returns: Json }
      test_sync_source: { Args: { p_id: string }; Returns: Json }
      test_webhook: { Args: { p_webhook_id: string }; Returns: Json }
      toggle_notification_star: {
        Args: { p_id: number }
        Returns: {
          body: string
          created_at: string
          event_key: string
          id: number
          read_at: string | null
          recipient_id: string
          ref_id: string | null
          ref_type: string | null
          source_module: string | null
          starred: boolean
          title: string
        }
        SetofOptions: {
          from: "*"
          to: "messages"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      trigger_sync_webhook: { Args: { p_token: string }; Returns: string }
      unpublish_report_definition: {
        Args: { p_def_id: string }
        Returns: {
          config: NonNullable<Json>
          created_at: string
          created_by: string | null
          id: string
          name: string
          owner_id: string
          source_view: string
          updated_at: string
          updated_by: string | null
          visibility: string
        }
        SetofOptions: {
          from: "*"
          to: "report_definitions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      unread_count: { Args: Record<PropertyKey, never>; Returns: number }
      update_webhook: {
        Args: {
          p_events: string[]
          p_headers?: Json
          p_id: string
          p_name: string
          p_retry_policy?: Json
          p_url: string
        }
        Returns: Json
      }
      upsert_announcement: {
        Args: {
          p_audience: string
          p_content: string
          p_ends_at: string
          p_id?: string
          p_pinned: boolean
          p_starts_at: string
          p_title: string
        }
        Returns: Json
      }
      upsert_data_scope: {
        Args: { p_role_id: string; p_scope: string }
        Returns: {
          role_id: string
          scope: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "role_data_scopes"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_department: {
        Args: {
          p_id: string
          p_leader_id: string
          p_name: string
          p_parent_id: string
          p_sort_order: number
        }
        Returns: {
          created_at: string
          created_by: string | null
          id: string
          leader_id: string | null
          name: string
          parent_id: string | null
          sort_order: number
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "departments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_dict_item: {
        Args: {
          p_color_class: string
          p_dict_key: string
          p_label: string
          p_sort_order: number
          p_status: string
          p_value: string
        }
        Returns: Json
      }
      upsert_dict_meta: {
        Args: { p_description: string; p_dict_key: string }
        Returns: Json
      }
      upsert_flow: {
        Args: {
          p_id?: string
          p_name: string
          p_nodes: Json
          p_template_id: string
        }
        Returns: {
          branches: Json | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          nodes: NonNullable<Json>
          status: string
          template_id: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_flows"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_form_template: {
        Args: {
          p_code: string
          p_id?: string
          p_module: string
          p_name: string
          p_schema: Json
        }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          module: string
          name: string
          schema: NonNullable<Json>
          status: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "approval_form_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_message_template: {
        Args: {
          p_body_tpl: string
          p_channel: string
          p_event_key: string
          p_id?: string
          p_subject_tpl: string
        }
        Returns: {
          body_tpl: string
          channel: string
          created_at: string
          event_key: string
          id: string
          status: string
          subject_tpl: string
          updated_at: string
          updated_by: string | null
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "message_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_position: {
        Args: {
          p_code?: string
          p_department_id?: string
          p_description?: string
          p_headcount?: number
          p_id?: string
          p_name?: string
          p_status?: string
        }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          department_id: string | null
          description: string | null
          headcount: number
          id: string
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "positions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_push_channel: {
        Args: {
          p_channel: string
          p_enabled: boolean
          p_secret: string
          p_webhook_url: string
        }
        Returns: Json
      }
      upsert_report_subscription: {
        Args: {
          p_channels?: string[]
          p_id: string
          p_preset: string
          p_recipients?: string
          p_report_def_id: string
          p_time?: string
          p_weekday?: number
        }
        Returns: {
          channels: string[]
          created_at: string
          created_by: string
          cron_expr: string
          id: string
          is_deleted: boolean
          recipients: string
          report_def_id: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "report_subscriptions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_role: {
        Args: {
          p_code: string
          p_description?: string
          p_id: string
          p_name: string
          p_status?: string
        }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          is_builtin: boolean
          name: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "roles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_row_version_whitelist: {
        Args: { p_enabled: boolean; p_table: string }
        Returns: Json
      }
      upsert_service_config: {
        Args: { p_config: Json; p_credentials: string; p_service: string }
        Returns: Json
      }
      upsert_setting: {
        Args: {
          p_description: string
          p_group_name: string
          p_key: string
          p_value: Json
          p_value_type: string
        }
        Returns: Json
      }
      upsert_sms_template: {
        Args: {
          p_id: string
          p_name: string
          p_provider_code: string
          p_scene: string
          p_status: string
        }
        Returns: Json
      }
      upsert_sync_schedule: {
        Args: {
          p_cron_expr?: string
          p_regenerate_token?: boolean
          p_status?: string
          p_task_id: string
          p_timezone?: string
          p_trigger_type: string
        }
        Returns: Json
      }
      upsert_sync_source: {
        Args: {
          p_config: Json
          p_credentials: string
          p_id: string
          p_name: string
          p_status?: string
          p_type: string
        }
        Returns: Json
      }
      upsert_sync_task: {
        Args: {
          p_conflict_policy: string
          p_direction: string
          p_field_mapping: Json
          p_id: string
          p_name: string
          p_source_id: string
          p_status?: string
          p_target_table: string
        }
        Returns: Json
      }
      urge_instance: {
        Args: { p_instance_id: string }
        Returns: {
          created_at: string
          current_seq: number
          flow_version_id: string
          form_data: NonNullable<Json>
          id: string
          initiator_id: string
          last_urged_at: string | null
          module: string
          ref_id: string | null
          ref_type: string | null
          status: string
          template_version_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "approval_instances"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      validate_department_move: {
        Args: { p_new_parent: string; p_node: string }
        Returns: undefined
      }
      visible_menus: {
        Args: Record<PropertyKey, never>
        Returns: {
          fallback: boolean
          key: string
          label: string
          module: string
          parent_key: string
          route: string
          sort_order: number
        }[]
      }
      webhook_test_result: { Args: { p_request_id: number }; Returns: Json }
      withdraw_instance: {
        Args: { p_instance_id: string }
        Returns: {
          created_at: string
          current_seq: number
          flow_version_id: string
          form_data: NonNullable<Json>
          id: string
          initiator_id: string
          last_urged_at: string | null
          module: string
          ref_id: string | null
          ref_type: string | null
          status: string
          template_version_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "approval_instances"
          isOneToOne: true
          isSetofReturn: false
        }
      }
    }
    Enums: {
      profile_status: "active" | "inactive"
      user_role:
        | "admin"
        | "engineer"
        | "planner"
        | "buyer"
        | "quality"
        | "supplier"
        | "customer"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      profile_status: ["active", "inactive"],
      user_role: [
        "admin",
        "engineer",
        "planner",
        "buyer",
        "quality",
        "supplier",
        "customer",
      ],
    },
  },
} as const
