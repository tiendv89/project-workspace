# Product Specification

## Feature
- Feature ID: `m1-admin-panel`
- Title: `M1 Admin Panel`

## Problem
There is currently no way for workspace administrators to manage membership. Users cannot be invited to or removed from a workspace through the product — access control is handled entirely outside the system (e.g. manually in the database or by a developer). This creates operational friction and makes onboarding new team members slow and error-prone.

## Goals
- Provide an admin panel UI where workspace administrators can view all current members
- Allow admins to invite new users to a workspace (by email)
- Allow admins to remove existing users from a workspace
- Ensure only users with an admin role can access the panel

## Non-goals
- Self-serve user registration or public sign-up flows
- Role management beyond admin / member distinction (e.g. custom roles, granular permissions)
- Bulk import of users (CSV upload, directory sync)
- Audit log or activity history for membership changes (may be addressed in a later milestone)
