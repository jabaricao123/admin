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
        Insert: {
          created_at?: string
          department?: string | null
          department_id?: string | null
          email?: string | null
          full_name?: string | null
          id: string
          position_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          role_id?: string | null
          status?: Database["public"]["Enums"]["profile_status"]
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          department?: string | null
          department_id?: string | null
          email?: string | null
          full_name?: string | null
          id?: string
          position_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          role_id?: string | null
          status?: Database["public"]["Enums"]["profile_status"]
          updated_at?: string
          updated_by?: string | null
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
      get_role_user_counts: {
        Args: Record<PropertyKey, never>
        Returns: {
          role_code: string
          role_id: string
          user_count: number
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
      get_storage_usage: {
        Args: Record<PropertyKey, never>
        Returns: {
          bucket_id: string
          object_count: number
          total_bytes: number
        }[]
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
          initiator_name: string | null
          instance_id: string
          instance_status: string
          last_urged_at: string | null
          module: string
          ref_id: string | null
          ref_type: string | null
          schema: Json
          tasks: Json
          title: string
          updated_at: string
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
          cc_read_at: string | null
          current_assignee_id: string | null
          current_assignee_name: string | null
          current_seq: number
          current_task_id: string | null
          current_task_status: string | null
          form_data: Json
          initiator_id: string
          initiator_name: string | null
          instance_id: string
          instance_status: string
          module: string
          ref_id: string | null
          ref_type: string | null
          title: string
        }[]
      }
      my_instances: {
        Args: { p_limit?: number }
        Returns: {
          created_at: string
          current_acted_at: string | null
          current_assignee_id: string | null
          current_assignee_name: string | null
          current_comment: string | null
          current_seq: number
          current_task_id: string | null
          current_task_status: string | null
          form_data: Json
          instance_id: string
          instance_status: string
          last_urged_at: string | null
          module: string
          ref_id: string | null
          ref_type: string | null
          title: string
          updated_at: string
        }[]
      }
      my_todos: {
        Args: { p_limit?: number; p_pending?: boolean }
        Returns: {
          acted_at: string | null
          comment: string | null
          created_at: string
          current_seq: number
          form_data: Json
          initiator_id: string
          initiator_name: string | null
          instance_id: string
          instance_status: string
          module: string
          ref_id: string | null
          ref_type: string | null
          seq: number
          task_id: string
          task_status: string
          title: string
        }[]
      }
      position_headcount: { Args: { p_position_id: string }; Returns: number }
      preview_scope: { Args: { p_user_id: string }; Returns: Json }
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
      test_storage_config: { Args: Record<PropertyKey, never>; Returns: Json }
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
      unread_count: { Args: Record<PropertyKey, never>; Returns: number }
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
      upsert_service_config: {
        Args: { p_config: Json; p_credentials: string; p_service: string }
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
