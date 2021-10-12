function Tables.schema(layer::AbstractFeatureLayer)::Nothing
    return nothing
end

Tables.istable(::Type{<:AbstractFeatureLayer})::Bool = true
Tables.rowaccess(::Type{<:AbstractFeatureLayer})::Bool = true

function Tables.rows(layer::T)::T where {T<:AbstractFeatureLayer}
    return layer
end

function Tables.getcolumn(row::Feature, i::Int)
    if i > nfield(row)
        return getgeom(row, i - nfield(row) - 1)
    elseif i > 0
        return getfield(row, i - 1)
    else
        return missing
    end
end

function Tables.getcolumn(row::Feature, name::Symbol)
    field = getfield(row, name)
    if !ismissing(field)
        return field
    end
    geom = getgeom(row, name)
    if geom.ptr != C_NULL
        return geom
    end
    return missing
end

function Tables.columnnames(
    row::Feature,
)::NTuple{Int64(nfield(row) + ngeom(row)),Symbol}
    geom_names, field_names = schema_names(getfeaturedefn(row))
    return (geom_names..., field_names...)
end

function schema_names(featuredefn::IFeatureDefnView)
    fielddefns = (getfielddefn(featuredefn, i) for i in 0:nfield(featuredefn)-1)
    field_names = (Symbol(getname(fielddefn)) for fielddefn in fielddefns)
    geom_names = collect(
        Symbol(getname(getgeomdefn(featuredefn, i - 1))) for
        i in 1:ngeom(featuredefn)
    )
    return (geom_names, field_names, featuredefn, fielddefns)
end

"""
    convert_coltype_to_AGtype(T, colidx)

Convert a table column type to ArchGDAL IGeometry or OGRFieldType/OGRFieldSubType
Conforms GDAL version 3.3 except for OFTSJSON and OFTSUUID
"""
function _convert_coltype_to_AGtype(T::Type, colidx::Int64)::Union{OGRwkbGeometryType, Tuple{OGRFieldType, OGRFieldSubType}}
    flattened_T = Base.uniontypes(T)
    clean_flattened_T = filter(t -> t ∉ [Missing, Nothing], flattened_T)
    promoted_clean_flattened_T = promote_type(clean_flattened_T...)
    if promoted_clean_flattened_T <: IGeometry
        # IGeometry
        return if promoted_clean_flattened_T == IGeometry
            wkbUnknown
        else
            convert(OGRwkbGeometryType, promoted_clean_flattened_T)
        end
    elseif promoted_clean_flattened_T isa DataType
        # OGRFieldType and OGRFieldSubType or error
        # TODO move from try-catch with convert to if-else with collections (to be defined)
        oft::OGRFieldType = try 
            convert(OGRFieldType, promoted_clean_flattened_T)
        catch e
            if !(e isa MethodError)
                error("Cannot convert type: $T of column $colidx to OGRFieldType and OGRFieldSubType")
            else
                rethrow()
            end
        end
        if oft ∉ [OFTInteger, OFTIntegerList, OFTReal, OFTRealList] # TODO consider extension to OFTSJSON and OFTSUUID
            ofst = OFSTNone
        else
            ofst::OGRFieldSubType = try
                convert(OGRFieldSubType, promoted_clean_flattened_T)
            catch e
                e isa MethodError ? OFSTNone : rethrow()
            end
        end

        return oft, ofst
    else
        error("Cannot convert type: $T of column $colidx to neither IGeometry{::OGRwkbGeometryType} or OGRFieldType and OGRFieldSubType")
    end 
end

function IFeatureLayer(table::T)::IFeatureLayer where {T}
    # Check tables interface's conformance
    !Tables.istable(table) &&
        throw(DomainError(table, "$table has not a Table interface"))
    # Extract table data
    rows = Tables.rows(table)
    schema = Tables.schema(table)
    schema === nothing && error("$table has no Schema")
    names = string.(schema.names)
    types = schema.types
    # TODO consider the case where names == nothing or types == nothing
    
    # Convert types and split types/names between geometries and fields
    AG_types = _convert_coltype_to_AGtype.(types, 1:length(types))

    geomindices = isa.(AG_types, OGRwkbGeometryType)
    !any(geomindices) && error("No column convertible to geometry")
    geomtypes = AG_types[geomindices] # TODO consider to use a view
    geomnames = names[geomindices]
    
    fieldindices = isa.(AG_types, Tuple{OGRFieldType, OGRFieldSubType})
    fieldtypes = AG_types[fieldindices] # TODO consider to use a view
    fieldnames = names[fieldindices]
    
    # Create layer
    layer = createlayer(geom=first(geomtypes))
    # TODO: create setname! for IGeomFieldDefnView. Probably needs first to fix issue #215
    # TODO: "Model and handle relationships between GDAL objects systematically"
    GDAL.ogr_gfld_setname(getgeomdefn(layerdefn(layer), 0).ptr, first(geomnames))

    # Create FeatureDefn
    if length(geomtypes) ≥ 2
        for (j, geomtype) in enumerate(geomtypes[2:end])
            creategeomdefn(geomnames[j+1], geomtype) do geomfielddefn
                addgeomdefn!(layer, geomfielddefn) # TODO check if necessary/interesting to set approx=true
            end
        end
    end
    for (j, (ft, fst)) in enumerate(fieldtypes)    
        createfielddefn(fieldnames[j], ft) do fielddefn
            setsubtype!(fielddefn, fst)
            addfielddefn!(layer, fielddefn)
        end
    end

    # Populate layer
    for (i, row) in enumerate(rows)
        rowgeoms = view(row, geomindices)
        rowfields = view(row, fieldindices)
        addfeature(layer) do feature
            # TODO: optimize once PR #238 is merged define in casse of `missing` 
            # TODO: or `nothing` value, geom or field as to leave unset or set to null
            for (j, val) in enumerate(rowgeoms)
                val !== missing && val !== nothing && setgeom!(feature, j-1, val)
            end
            for (j, val) in enumerate(rowfields)
                val !== missing && val !== nothing && setfield!(feature, j-1, val)
            end
        end
    end

    return layer
end